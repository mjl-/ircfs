implement WmIrc;

include "sys.m";
include "draw.m";
include "string.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "plumbmsg.m";
include "tk.m";
include "tkclient.m";
include "irc.m";
include "keyboard.m";

sys: Sys;
draw: Draw;
str: String;
plumbmsg: Plumbmsg;
tk: Tk;
tkclient: Tkclient;
irc: Irc;

sprint, fprint, print, fildes: import sys;
Msg: import plumbmsg;

Windowlinesmax: con 8*1024;

datach: chan of (ref Win.Irc, list of string);
eventch: chan of (ref Srv, list of string);
usersch: chan of (ref Win.Irc, string);
writererrch: chan of (ref Win.Irc, string);

# connection to an ircfs
lastsrvid := 0;		# unique id's
Srv: adt {
	id:	string;		# lastsrvid
	path:	string;	
	ctlfd:	ref Sys->FD;
	nick, lnick:	string;	# our name and lowercase
	eventpid:	int;
	win0:	cyclic ref Win.Irc;
	wins:	cyclic list of ref Win.Irc;		# includes win0
	unopen:	list of ref (string, string);	# name, id

	init:	fn(path: string): (ref Srv, string);
	addunopen:	fn(srv: self ref Srv, name, id: string);
	delunopen:	fn(srv: self ref Srv, id: string);
	haveopen:	fn(srv: self ref Srv, id: string): int;
};

None, Meta, Data, Highlight: con iota;	# Win.state

# window, an irc directory except for status window
Win: adt {
	name:	string;
	tkid:	string;
	listindex:	int;
	eof:	int;
	nlines:	int;		# lines in window
	status:	string;
	state:	int;

	pick {
	Irc =>
		srv:	ref Srv;
		id:	string;
		ctlfd, datafd:	ref Sys->FD;
		pids:	list of int;	# for reader, writer, usersreader
		ischan:	int;
		writec:	chan of string;
		users:	list of string;	# with case
	Status =>
	}

	init:	fn(srv: ref Srv, id, name: string): (ref Win.Irc, string);
	writetext:	fn(w: self ref Win, s: string): string;
	addline:	fn(w: self ref Win, l: string, tag: string);
	close:	fn(w: self ref Win);
	ctlwrite:	fn(w: self ref Win, s: string): string;
	setstate:	fn(w: self ref Win, state, draw: int);
	scroll:		fn(w: self ref Win);
	scrolltext:	fn(w: self ref Win, seetop, seebottom: int);
	visibletext:	fn(w: self ref Win): (int, int);
	plumbsend:	fn(w: self ref Win, text, key, val: string);
};

servers: list of ref Srv;
windows: array of ref Win;	# status window plus all windows in all servers
statuswin: ref Win.Status;
curwin, lastwin: ref Win;
plumbed: int;

dflag: int;
sflag: int;
readhistsize := big -1;
t: ref Tk->Toplevel;
wmctl: chan of string;
lineheight := 0;
width := 800;
height := 600;


WmIrc: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

tkcmds := array[] of {
	"frame .m",
	"frame .m.ctl",
	"frame .m.text",
	"frame .side",

	"button .snarf -text snarf -command {send cmd snarf; focus .l}",
	"button .paste -text paste -command {send cmd paste; focus .l}",
	"button .plumb -text plumb -command {send cmd plumb; focus .l}",
	"entry .find",
	"bind .find <Key-\n> {send cmd find}",
	"bind .find <Control-n> {send cmd findnext}",
	"bind .find <Control-t> {focus .l}",
	"button .next -text find -command {send cmd findnext}",
	"pack .snarf .paste .plumb -side left -in .m.ctl",
	"pack .next -side right -in .m.ctl",
	"pack .find -side right -in .m.ctl -fill x -expand 1",
	"pack .m.ctl -in .m -fill x",

	"entry .l",
	"bind .l <Key-\n> {send cmd say}",
	"bind .l <Control-p> {send cmd prevwin}",
	"bind .l <Control-n> {send cmd nextwin}",
	"bind .l <Control-k> {send cmd lastwin}",
	"bind .l <Control-z> {send cmd prevactivewin}",
	"bind .l <Control-x> {send cmd nextactivewin}",
	#"bind .l <Control-l> {send cmd clear}",
	"bind .l <Control-f> {focus .find}",
	"bind .l {<Key-\t>} {send cmd complete}",

	"listbox .targs -width 14w",
	"pack .targs -side right -in .side -fill y -expand 1",
	"bind .targs <ButtonRelease-1> {send cmd winsel; focus .l}",
	"bind .targs <Control-t> {focus .l}",

	"pack .m.text -in .m -fill both -expand 1",
	"pack .l -in .m -fill x",
	"pack .m -side right -fill both -expand 1",
	"pack .side -side left -fill y",
	"pack propagate . 0",
	"focus .l",
};

maketext(tkid: string)
{
	id := tkid;
	cmds := array[] of {
		sprint("frame .m.%s", id),
		sprint("text .%s -wrap word -yscrollcommand {.%s-scroll set}", id, id),
		# without the font-part, the lmargin seems to be ignored...
		sprint(".%s tag configure meta -foreground blue -font /fonts/pelm/unicode.8.font -lmargin2 6w", id),
		sprint(".%s tag configure warning -foreground red", id),
		sprint(".%s tag configure data -foreground black -font /fonts/pelm/unicode.8.font -lmargin2 16w", id),
		sprint(".%s tag configure hl -background yellow", id),
		sprint(".%s tag configure search -background orange", id),
		sprint(".%s tag configure status -foreground green", id),
		sprint(".%s tag configure bold -underline 1", id),
		sprint("bind .%s <Control-f> {focus .find}", id),
		sprint("bind .%s <Control-t> {focus .l}", id),
		sprint("scrollbar .%s-scroll -command {.%s yview}", id, id),
		sprint("pack .%s-scroll -side left -fill y -in .m.%s", id, id),
		sprint("pack .%s -side right -in .m.%s -fill both -expand 1", id, id),
		sprint("pack .m.%s -in .m.text", id),
		sprint("pack forget .m.%s", id),
	};
	for(i := 0; i < len cmds; i++)
		tkcmd(cmds[i]);
}

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(ctxt == nil)
		fail("no window context");
	draw = load Draw Draw->PATH;
	str = load String String->PATH;
	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	tk = load Tk Tk->PATH;
	tkclient= load Tkclient Tkclient->PATH;
	irc = load Irc Irc->PATH;
	irc->init(bufio);

	arg->init(args);
	arg->setusage(arg->progname()+" [-ds] [-g width height] [-h histsize] [path ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		'g' =>	width = int arg->earg();
			height = int arg->earg();
		'h' =>	readhistsize = big arg->earg();
		's' =>	sflag++;
		* =>	fprint(fildes(2), "bad option\n");
			arg->usage();
		}
	args = arg->argv();

	sys->pctl(Sys->NEWPGRP, nil);
	plumbed = plumbmsg->init(1, nil, 0) >= 0;
	tkclient->init();
	(t, wmctl) = tkclient->toplevel(ctxt, "", "irc", Tkclient->Appl);

	tkcmdchan := chan of string;
	tk->namechan(t, tkcmdchan, "cmd");
	for(i := 0; i < len tkcmds; i++)
		tkcmd(tkcmds[i]);
	tkcmd(sprint(". configure -width %d -height %d", width, height));

	maketext("status");
	statuswin = ref Win.Status("status", "status", 0, 0, 0, "", None);
	lastwin = curwin = statuswin;
	fixwindows();
	tkwinwrite(statuswin, "status window", "meta");

	lineinfo := tkcmd(".status dlineinfo 1.0");
	linetoks := sys->tokenize(lineinfo, " ").t1;
	if(lineinfo == nil || linetoks == nil)
		fail("could not get lineheight");
	lineheight = int hd tl tl tl linetoks;

	datach = chan of (ref Win.Irc, list of string);
	eventch = chan of (ref Srv, list of string);
	usersch = chan of (ref Win.Irc, string);
	writererrch = chan[1] of (ref Win.Irc, string);

	for(; args != nil; args = tl args) {
		(srv, err) := Srv.init(hd args);
		if(err != nil) {
			tkwarn(err);
			continue;
		}
		servers = srv::servers;
		say("have new srv");
	}

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd"::"ptr"::nil);

	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or s = <-t.wreq =>
		tkclient->wmctl(t, s);
	menu := <-wmctl =>
		case menu {
		"exit" =>
			killgrp(sys->pctl(0, nil));
			exit;
		* =>
			tkclient->wmctl(t, menu);
		}

	cmd := <-tkcmdchan =>
		dotk(cmd);

	(ircwin, lines) := <-datach =>
		dodata(ircwin, lines);

	(srv, tokens) := <-eventch =>
		doevent(srv, tokens);

	(ircwin, s) := <-usersch =>
		douser(ircwin, s);

	(w, err) := <-writererrch =>
		tkwinwarn(w, "writing: "+err);
	}
}

dotk(cmd: string)
{
	(word, nil) := str->splitstrl(cmd, " ");
	say(sprint("tk ui cmd: %q", word));

	case word {
	"find" or "findnext" =>
		start := "1.0";
		if(word == "findnext") {
			nstart := tkcmd(sprint(".%s tag nextrange search 1.0", curwin.tkid));
			if(nstart != nil && nstart[0] != '!')
				(start, nil) = str->splitstrl(nstart, " ");
		}
		tkcmd(sprint(".%s tag remove search 1.0 end", curwin.tkid));
		pattern := tkget(".find get");
		if(pattern != nil) {
			index := tkcmd(sprint(".%s search [.find get] {%s +%dc}", curwin.tkid, start, len pattern));
			say("find, index: "+index);
			if(index != nil && index[0] != '!')
				tkcmd(sprint(".%s tag add search %s {%s +%dc}; .%s see %s",
					curwin.tkid, index, index, len pattern, curwin.tkid, index));
		}
		tkcmd("update");

	"snarf" =>
		s := selection();
		if(s != nil)
			writefile("/dev/snarf", s);

	"paste" =>
		(s, nil) := readfile("/dev/snarf");
		if(str->drop(s, "^\n") == nil) {
			tkcmd(".l insert insert '"+s);
			tkcmd("update");
			return;
		}
		pick win := curwin {
		Irc =>
			err := win.writetext(s);
			if(err != nil)
				tkwarn("writing: "+err);
		Status =>
			tkwarn("cannot paste to status window");
		}

	"plumb" =>
		s := selection();
		if(s != nil)
			curwin.plumbsend(s, "name", curwin.name);

	"nextwin" =>
		showwindow(windows[(curwin.listindex+1)%len windows]);

	"prevwin" =>
		showwindow(windows[(curwin.listindex-1+len windows)%len windows]);

	"lastwin" =>
		showwindow(lastwin);

	"prevactivewin" =>
		off := curwin.listindex;
		which := array[] of {Highlight, Data, Meta};
		for(w := 0; w < len which; w++)
			for(i := len windows; i >= 0; i--)
				if(windows[(i+off)%len windows].state == which[w])
					return showwindow(windows[(i+off)%len windows]);

	"nextactivewin" =>
		off := curwin.listindex;
		which := array[] of {Highlight, Data, Meta};
		for(w := 0; w < len which; w++)
			for(i := 0; i < len windows; i++)
				if(windows[(i+off)%len windows].state == which[w])
					return showwindow(windows[(i+off)%len windows]);

	"clear" =>
		tkcmd(sprint(".%s delete 1.0 end; update", curwin.tkid));

	"say" =>
		line := tkget(".l get");
		if(line == nil)
			return;
		tkcmd(".l delete 0 end; update");
		if(str->prefix("/", line) && !str->prefix("//", line)) {
			command(line[1:]);
			return;
		}

		pick win := curwin {
		Irc =>
			say("say line");
			if(line[0] == '/')
				line = line[1:];
			err := win.writetext(line);
			if(err != nil)
				tkwarn("writing: "+err);
		Status =>
			tkwarn("not an irc window");
		}

	"complete" =>
		pick win := curwin {
		Irc =>
			l := tkget(".l get");

			index := int tkcmd(".l index insert");
			if(index < 0 || index > len l)
				return;
			w := str->tolower(taketl(l[:index], "^ \t"));
			say(sprint("complete, w %q", w));

			for(ul := win.users; ul != nil; ul = tl ul) {
				if(!str->prefix(w, str->tolower(hd ul)))
					continue;

				start := index-len w;
				suf := " ";
				if(start == 0)
					suf = ": ";
				tkcmd(sprint(".l delete %d %d; .l insert %d '%s", start, index, start, hd ul+suf));
				tkcmd("update");
				break;
			}
		}

	"winsel" =>
		say("winsel");
		index := int tkcmd(".targs curselection");
		showwindow(windows[index]);

	* =>
		tkstatuswarn(sprint("bad command: %q\n", cmd));
	}
}

dodata(win: ref Win.Irc, lines: list of string)
{
	if(lines == nil) {
		win.addline("eof\n", "warning");
		win.eof = 1;
		return;
	}

	(seetop, seebottom) := win.visibletext();

	nlines := len lines;
	for(; lines != nil; lines = tl lines) {
		m := hd lines;
		if(len m < 2) {
			tkstatuswarn(sprint("bad data line: %q", m));
			continue;
		}
		tag := "data";
		nostatechange := m[:2] == "! ";
		if(m[:2] == "# " || m[:2] == "! ")
			tag = "meta";

		(mm, bolds) := uncrap(m[2:]);
		m = mm+"\n";
		win.addline(m, tag);

		for(; bolds != nil; bolds = tl bolds) {
			(start, end) := *hd bolds;
			tkcmd(sprint(".%s tag add bold {end -1c linestart +%dc} {end -1 linestart +%dc}", win.tkid, start, end));
		}

		hl := substr(win.srv.lnick, irc->lowercase(m));
		if(hl >= 0)
			tkcmd(sprint(".%s tag add hl {end -1c linestart +%dc} {end -1 linestart +%dc +%dc}",
				win.tkid, hl, hl, len win.srv.nick));

		# at startup, we read a backlog.  these lines will be sent many lines in one read.
		# during normal operation we typically get one line per read.
		# this is a simple heuristic to start without all windows highlighted...
		if(nlines == 1 && win != curwin && !nostatechange) {
			if(tag == "meta")
				win.setstate(Meta, 1);
			else if(!win.ischan || hl >= 0)
				win.setstate(Highlight, 1);
			else
				win.setstate(Data, 1);
		}
	}
	win.scrolltext(seetop, seebottom);
	tkcmd("update");
}

doevent(srv: ref Srv, tokens: list of string)
{
	event := hd tokens;
	tokens = tl tokens;
	case event {
	"new" =>
		if(len tokens != 2) {
			tkstatuswarn(sprint("bad 'new' message"));
			return;
		}

		id := hd tokens;
		name := hd tl tokens;
		if(srv.haveopen(id)) {
			tkstatuswarn(sprint("new window, but already present: %q (%q)", name, id));
			return;
		}
		srv.addunopen(name, id);
		if(!sflag || id == "0") {
			(win, err) := Win.init(srv, id, name);
			if(err != nil) {
				tkwarn(err);
				return;
			}
			addwindow(win);
		} else if(srv.win0 != nil)
			tkwinwrite(srv.win0, sprint("new window: %q (%q)", name, id), "status");
		say(sprint("have new target, path=%q id=%q", srv.path, id));

	"del" =>
		id := hd tokens;
		say(sprint("del target %q", id));
		srv.delunopen(id);

	"nick" =>
		srv.nick = hd tokens;
		say(sprint("new nick: %q", srv.nick));
		srv.lnick = irc->lowercase(srv.nick);

	"disconnected" =>
		say("disconnected");
		tkstatuswarn(sprint("disconnected: %q", srv.path));

	"connected" =>
		srv.nick = hd tokens;
		srv.lnick = irc->lowercase(srv.nick);
		tkstatuswarn(sprint("connected %q: %q", srv.path, srv.nick));

	"connecting" =>
		tkstatuswarn(sprint("connecting: %q", srv.path));
	}
}

douser(w: ref Win.Irc, s: string)
{
	(nil, ll) := sys->tokenize(s, "\n");
	for(; ll != nil; ll = tl ll) {
		l := hd ll;
		if(l != nil && l[len l-1] == '\n')
			l = l[:len l-1];
		if(l == nil) {
			tkstatuswarn("empty user line");
			continue;
		}
		say(sprint("userline=%q", l));
		user := l[1:];
		case l[0] {
		'+' =>	w.users = user::w.users;
		'-' =>	users: list of string;
			for(; w.users != nil; w.users = tl w.users)
				if(hd w.users != user)
					users = hd w.users::users;
			w.users = users;
		* =>	tkstatuswarn(sprint("bad user line: %q", l));
		}
	}
}

uncrap(s: string): (string, list of ref (int, int))
{
	r := "";
	bolds: list of ref (int, int);
	bold := 0;
	for(i := 0; i < len s; i++)
		case s[i] {
		2 =>	# starts/ends bold
			if(bold) {
				bolds = ref(bold, len r)::bolds;
				bold = 0;
			} else
				bold = len r;
		3 =>	# introduces color (and 2-digit code)
			if(i+2 < len s && str->in(s[i+1], "0-9") && str->in(s[i+2], "0-9"))
				i += 2;
		31 =>	# starts/ends underlined
			;
		# not yet seen in wild:
		# 22 =>	# starts/ends italic
		# 	;
		* =>	r[len r] = s[i];
		}
	return (r, rev(bolds));
}

command(line: string)
{
	(cmd, rem) := str->splitstrl(line, " ");

	case cmd {
	"add" =>
		rem = str->drop(rem, " \t");
		say(sprint("adding server %q", rem));
		(srv, err) := Srv.init(rem);
		if(err != nil)
			tkwarn(err);
		else
			servers = srv::servers;
		return;

	"exit" =>
		killgrp(sys->pctl(0, nil));
		exit;

	"clear" =>
		tkcmd(sprint(".%s delete 1.0 end; update", curwin.tkid));
		return;
	}

	ircwin: ref Win.Irc;
	pick win := curwin {
	Status =>
		tkwarn("not an irc window");
		return;
	Irc =>
		ircwin = win;
	}

	err: string;
	case cmd {
	"close" =>
		if(curwin == ircwin.srv.win0)
			err = "cannot remove irc status window";
		else
			delwindow(ircwin);

	"del" =>
		srv := ircwin.srv;
		for(wl := srv.wins; wl != nil; wl = tl wl)
			(hd wl).close();
		servers = del(srv, servers);
		kill(srv.eventpid);
		curwin = lastwin;
		pick win := lastwin {
		Irc =>
			if(win.srv == srv)
				curwin = lastwin = statuswin;
		}
		fixwindows();

	"addwin" =>
		rem = str->drop(rem, " \t");
		if(ircwin.srv.haveopen(rem))
			err = "window already open";
		win: ref Win.Irc;
		if(err == nil)
			(win, err) = Win.init(ircwin.srv, rem, nil);
		if(err == nil) {
			addwindow(win);
			showwindow(win);
			say(sprint("have new target, path=%q id=%q", ircwin.srv.path, rem));
		}

	"windows" =>
		tkstatus("open:");
		for(wl := rev(ircwin.srv.wins); wl != nil; wl = tl wl)
			tkstatus(sprint("\t%-15s (%q)", (hd wl).name, (hd wl).id));
		tkstatus("not open:");
		for(l := ircwin.srv.unopen; l != nil; l = tl l)
			tkstatus(sprint("\t%-15s (%q)", (hd l).t0, (hd l).t1));

	"away" =>
		for(l := servers; l != nil; l = tl l)
			if(fprint((hd l).ctlfd, "%s", line) < 0)
				tkwarn(sprint("%q: %r", (hd l).path));

	* =>
		err = curwin.ctlwrite(line);
	}
	if(err != nil)
		tkwarn(err);
}

Srv.init(path: string): (ref Srv, string)
{
	eventb := bufio->open(path+"/event", Sys->OREAD);
	if(eventb == nil)
		return (nil, sprint("open: %r"));

	ctlfd := sys->open(path+"/ctl", Sys->OWRITE);
	if(ctlfd == nil)
		return (nil, sprint("open: %r"));

	srv := ref Srv(string (lastsrvid++), path, ctlfd, nil, nil, 0, nil, nil, nil);

	spawn eventreader(pidc := chan of int, eventb, srv);
	srv.eventpid = <-pidc;
	return (srv, nil);
}

Srv.addunopen(srv: self ref Srv, name, id: string)
{
	srv.delunopen(id);
	srv.unopen = ref (name, id)::srv.unopen;
}

Srv.delunopen(srv: self ref Srv, id: string)
{
	unopen: list of ref (string, string);
	for(; srv.unopen != nil; srv.unopen = tl srv.unopen)
		if((hd srv.unopen).t1 != id)
			unopen = hd srv.unopen::unopen;
	srv.unopen = rev(unopen);
}

Srv.haveopen(srv: self ref Srv, id: string): int
{
	for(wl := srv.wins; wl != nil; wl = tl wl)
		if((hd wl).id == id)
			return 1;
	return 0;
}

eventreader(pidc: chan of int, b: ref Iobuf, srv: ref Srv)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		l := b.gets('\n');
		if(l == nil) {
			warn(sprint("eventreader eof/error: %r"));
			break;
		}
		if(l[len l-1] == '\n')
			l = l[:len l-1];
		say(sprint("have event"));
		(nil, tokens) := sys->tokenize(l, " ");
		eventch <-= (srv, tokens);
	}
}


Win.init(srv: ref Srv, id, name: string): (ref Win.Irc, string)
{
	p := sprint("%s/%s", srv.path, id);

	datafd := sys->open(p+"/data", Sys->ORDWR);
	if(datafd == nil)
		return (nil, sprint("open: %r"));
	if(readhistsize >= big 0) {
		dir := sys->nulldir;
		dir.length = readhistsize;
		if(sys->fwstat(datafd, dir) < 0)
			tkstatuswarn(sprint("set history size: %r"));
	}

	if(name == nil) {
		err: string;
		(name, err) = readfile(p+"/name");
		if(err != nil)
			return (nil, err);
	}
	usersfd := sys->open(p+"/users", Sys->OREAD);
	if(usersfd == nil)
		return (nil, sprint("open: %r"));

	tkid := sprint("t-%s-%s", srv.id, id);
	win := ref Win.Irc(name, tkid, -1, 0, 0, nil, None, srv, id, nil, datafd, nil, irc->ischannel(name), chan[8] of string, nil);
	win.setstate(None, 0);
	pidc := chan of int;
	spawn reader(pidc, datafd, win);
	spawn writer(pidc, datafd, win);
	spawn usersreader(pidc, usersfd, win);
	win.pids = <-pidc::<-pidc::<-pidc::win.pids;
	return (win, nil);
}

reader(pidc: chan of int, fd: ref Sys->FD, win: ref Win.Irc)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[Sys->ATOMICIO] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n == 0) {
			datach <-= (win, nil);
			break;
		}
		if(n < 0) {
			warn(sprint("read error: %r"));
			break;
		}
		(nil, lines) := sys->tokenize(string buf[:n], "\n");
		datach <-= (win, lines);
	}
}

writer(pidc: chan of int, fd: ref Sys->FD, w: ref Win.Irc)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		l := <-w.writec;
		if(l == nil)
			break;
		n := sys->write(fd, d := array of byte l, len d);
		if(n != len d)
			writererrch <-= (w, sys->sprint("%r"));
	}
}

usersreader(pidc: chan of int, fd: ref Sys->FD, w: ref Win.Irc)
{
	pidc <-= sys->pctl(0, nil);
	d := array[1024] of byte;
	for(;;) {
		n := sys->read(fd, d, len d);
		if(n == 0)
			break;
		if(n < 0) {
			warn(sprint("reading users: %r"));
			break;
		}
		usersch <-= (w, string d[:n]);
	}
}

Win.writetext(w: self ref Win, s: string): string
{
	pick ircwin := w {
	Irc =>
		alt {
		ircwin.writec <-= s =>	return nil;
		* =>			return "too many writes queued, discarding line";
		}
	Status =>
		return "bug: no writes to status window";
	}
}

Win.addline(w: self ref Win, l: string, tag: string)
{
	if(w.nlines >= Windowlinesmax)
		tkcmd(sprint(".%s delete 1.0 1.end", w.tkid));
	else
		w.nlines++;

	tkcmd(sprint(".%s insert end '%s", w.tkid, l));
	tkcmd(sprint(".%s tag add %s {end -1c -%dc} {end - 1c}", w.tkid, tag, len l));
}

Win.close(w: self ref Win)
{
	pick ircwin := w {
	Irc =>
		for(pids := ircwin.pids; pids != nil; pids = tl pids)
			kill(hd pids);
	}
	tkcmd(sprint("destroy .%s; destroy .m.%s; destroy .%s-scroll", w.tkid, w.tkid, w.tkid));
}

Win.ctlwrite(win: self ref Win, s: string): string
{
	pick w := win {
	Irc =>
		if(w.ctlfd == nil)
			w.ctlfd = sys->open(sprint("%s/%s/ctl", w.srv.path, w.id), Sys->OWRITE);
		if(w.ctlfd == nil || fprint(w.ctlfd, "%s", s) < 0)
			return sprint("%r");
		return nil;
	Status =>
		return "bug: no ctl for status window";
	}
}

Win.setstate(w: self ref Win, state, draw: int)
{
	if(state <= w.state && state != None)
		return;
	pick win := w {
	Irc =>
		c := ' ';
		case w.state = state {
		Highlight =>	c = '=';
				w.plumbsend(nil, "highlight", w.name);
		Data =>		c = '+';
		Meta =>		c = '-';
		}

		ws := " ";
		if(win.id == "0")
			ws = "";
		w.status = sprint("%c%s", c, ws);
	}
	if(draw)
		tkcmd(sprint(".targs delete %d; .targs insert %d {%s%s}", w.listindex, w.listindex, w.status, w.name));
}

Win.scroll(w: self ref Win)
{
	(seetop, seebottom) := w.visibletext();
	w.scrolltext(seetop, seebottom);
}

Win.visibletext(w: self ref Win): (int, int)
{
	if(lineheight == 0)
		return (0, 0);

	where := tkcmd(sprint("see -where .%s", w.tkid));
	textlines := int hd tl tl tl sys->tokenize(where, " ").t1/lineheight;

	seetop := tkcmd(sprint(".%s dlineinfo {end -%d lines}", w.tkid, textlines)) != nil;
	seebottom := tkcmd(sprint(".%s dlineinfo {end -2 lines}", w.tkid)) != nil;
	return (seetop, seebottom);
}

Win.scrolltext(w: self ref Win, seetop, seebottom: int)
{
	if(lineheight == 0)
		return;

	where := tkcmd(sprint("see -where .%s", w.tkid));
	textlines := int hd tl tl tl sys->tokenize(where, " ").t1/lineheight;

	if(seebottom && !seetop)
		tkcmd(sprint(".%s yview {end -%d lines}", w.tkid, textlines));
	if(seebottom)
		tkcmd(sprint(".%s see {end -1c lineend}", w.tkid));
}

Win.plumbsend(w: self ref Win, text, key, val: string)
{
	if(!plumbed)
		return;
	path := w.name;
	pick ircwin := w {
	Irc =>
		path = sprint("%s/%s/", ircwin.srv.path, ircwin.id);
	}
	attrs := plumbmsg->attrs2string(ref Plumbmsg->Attr(key, val)::nil);
	msg := ref Msg("WmIrc", "", path, "text", attrs, array of byte text);
	msg.send();
}

showwindow(w: ref Win)
{
	say("show");
	tkcmd(sprint("pack forget .m.%s", curwin.tkid));

	tkcmd(sprint("bind .l <Control-\\-> {.%s yview scroll -0.75 page}", w.tkid));
	tkcmd(sprint("bind .l <Control-=> {.%s yview scroll 0.75 page}", w.tkid));
	tkcmd(sprint("bind .l <Key-%c> {.%s yview scroll -0.75 page}", Keyboard->Pgup, w.tkid));
	tkcmd(sprint("bind .l <Key-%c> {.%s yview scroll 0.75 page}", Keyboard->Pgdown, w.tkid));
	tkcmd(sprint("pack .m.%s -in .m.text -fill both -expand 1", w.tkid));
	w.scroll();

	w.setstate(None, 1);
	tkcmd(sprint(".targs selection clear 0 end; .targs selection set %d; .targs see %d; update", w.listindex, w.listindex));
	lastwin = curwin;
	curwin = w;
}


fixwindows()
{
	nwins := 1;
	for(s := servers; s != nil; s = tl s)
		nwins += len (hd s).wins;
	wins := array[nwins] of ref Win;
	wins[0] = statuswin;
	index := 1;
	useindex := -1;
	for(s = rev(servers); s != nil; s = tl s)
		for(wl := rev((hd s).wins); wl != nil; wl = tl wl) {
			w := hd wl;
			w.listindex = index;
			if(w == curwin)
				useindex = index;
			if(w == lastwin && useindex < 0)
				useindex = index;
			wins[index++] = w;
		}

	windows = wins;

	tkcmd(sprint(".targs delete 0 end"));
	for(i := 0; i < len windows; i++) {
		w := windows[i];
		tkcmd(sprint(".targs insert %d {%s%s}", w.listindex, w.status, w.name));
	}

	if(useindex < 0)
		useindex = 0;
	tkcmd(sprint(".targs selection set %d; .targs see %d; update", useindex, useindex));
	showwindow(windows[useindex]);
}

addwindow(w: ref Win.Irc)
{
	maketext(w.tkid);
	w.srv.delunopen(w.id);
	w.srv.wins = w::w.srv.wins;

	if(w.id == "0")
		w.srv.win0 = w;
	fixwindows();
}

delwindow(w: ref Win.Irc)
{
	w.srv.wins = del(w, w.srv.wins);
	if(!w.eof)
		w.srv.addunopen(w.name, w.id);
	w.close();
	curwin = lastwin;
	if(lastwin == w)
		curwin = lastwin = statuswin;
	fixwindows();
}

selection(): string
{
	return tkget(sprint(".%s get sel.first sel.last", curwin.tkid));
}

tkwinwrite(w: ref Win, s, tag: string)
{
	s += "\n";
	w.addline(s, tag);
	w.scroll();
}

tkwinwarn(w: ref Win, s: string)
{
	tkwinwrite(w, s, "warning");
}

tkstatuswarn(s: string)
{
	tkwinwarn(statuswin, s);
}

tkwarn(s: string)
{
	tkwinwrite(curwin, s, "warning");
}

tkstatus(s: string)
{
	tkwinwrite(curwin, s, "status");
}

writefile(p: string, s: string): string
{
	fd := sys->open(p, Sys->OWRITE);
	if(fd == nil || sys->write(fd, d := array of byte s, len d) != len d)
		return sprint("open/write: %r");
	return nil;
}

readfile(p: string): (string, string)
{
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil || (n := sys->readn(fd, buf := array[Sys->ATOMICIO] of byte, len buf)) < 0)
		return (nil, sprint("open/read: %r"));
	return (string buf[:n], nil);
}

tkcmd(s: string): string
{
	r := tk->cmd(t, s);
	if(r != nil && r[0] == '!')
		warn(sprint("tkcmd: %q: %s", s, r));
	return r;
}

# like tkcmd, but does not warn if result starts with ! (can be text)
tkget(s: string): string
{
	return tk->cmd(t, s);
}

substr(sub, s: string): int
{
	last := len s-len sub;
	for(i := 0; i <= last; i++)
		if(str->prefix(sub, s[i:]))
			return i;
	return -1;
}

taketl(s, cl: string): string
{
	for(i := len s; i > 0 && str->in(s[i-1], cl); i--)
		;
	return s[i:];
}

del[T](e: T, l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		if(hd l != e)
			r = hd l::r;
	return rev(r);
}

rev[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l::r;
	return r;
}

kill(pid: int)
{
	if(pid >= 0 && (fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE)) != nil)
		fprint(fd, "kill");
}

killgrp(pid: int)
{
	if((fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE)) != nil)
		fprint(fd, "killgrp");
}

say(s: string)
{
	if(dflag)
		fprint(fildes(2), "%s\n", s);
}

warn(s: string)
{
	fprint(fildes(2), "%s\n", s);
}

fail(s: string)
{
	fprint(fildes(2), "%s\n", s);
	raise "fail:"+s;
}
