implement WmIrc;

include "sys.m";
include "draw.m";
include "string.m";
include "arg.m";
include "tk.m";
include	"tkclient.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "plumbmsg.m";
include "irc.m";

sys: Sys;
draw: Draw;
str: String;
tk: Tk;
tkclient: Tkclient;
plumbmsg: Plumbmsg;
irc: Irc;

sprint, fprint, print, fildes: import sys;
Msg: import plumbmsg;
ischannel, lowercase: import irc;

Maxlines: con 8*1024;

eventch: chan of (ref Srv, list of string);
datach: chan of (ref Win, list of string);
writererrch: chan of (ref Win, string);
usersch: chan of (ref Win, string);

lastsrvid := 0;
Srv: adt {
	id, path:	string;
	ctlfd, eventfd:	ref Sys->FD;
	nick, lnick:	string;
	open, unopen, dead:	array of ref (string, string);

	start:	fn(path: string): (ref Srv, string);
};

None, Meta, Data, Highlight: con iota;	# Win.state

Win: adt {
	srv:	ref Srv;
	id, tkid:	string;
	name:	string;
	listindex:	int;
	ctlfd, datafd:	ref Sys->FD;
	nlines:	int;
	pids:	list of int;
	state, ischan:	int;
	writec:	chan of string;
	users:	array of string;

	start:	fn(srv: ref Srv, id, name: string): (ref Win, string);
	addline:	fn(w: self ref Win, l: string, tag: string);
	show:	fn(w: self ref Win);
	close:	fn(w: self ref Win);
	ctlwrite:	fn(w: self ref Win, s: string): string;
	setstatus:	fn(w: self ref Win, s: int);
};

servers := array[0] of ref Srv;
windows := array[0] of ref Win;
curwin, lastwin: ref Win;
plumbed: int;

dflag: int;
sflag: int;
readhistsize: string;
t: ref Tk->Toplevel;
wmctl: chan of string;


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
	"bind .l <Control-l> {send cmd clearwin}",
	"bind .l <Control-f> {focus .find}",
	"bind .l {<Key-\t>} {send cmd complete}",

	"listbox .targs -font /fonts/pelm/unicode.8.font -width 14w",
	"pack .targs -side right -in .side -fill y -expand 1",
	"bind .targs <ButtonRelease-1> {send cmd winsel; focus .l}",
	"bind .targs <Control-t> {focus .l}",

	"pack .m.text -in .m -fill both -expand 1",
	"pack .l -in .m -fill x",
	"pack .m -side right -fill both -expand 1",
	"pack .side -side left -fill y",
	"pack propagate . 0",
	". configure -width 800 -height 600",
	"focus .l",
	"update",
};

maketext(id: string)
{
	cmds := array[] of {
		sprint("frame .m.%s", id),
		sprint("text .%s -wrap word -yscrollcommand {.%sscroll set}", id, id),
		sprint(".%s tag configure meta -foreground blue -font /fonts/pelm/unicode.8.font -lmargin2 6w", id),
		sprint(".%s tag configure warning -foreground red", id),
		sprint(".%s tag configure data -foreground black -font /fonts/pelm/unicode.8.font -lmargin2 16w", id),
		sprint(".%s tag configure hl -background yellow", id),
		sprint(".%s tag configure search -background orange", id),
		sprint(".%s tag configure resp -foreground green", id),
		sprint("bind .%s <Control-f> {focus .find}", id),
		sprint("bind .%s <Control-t> {focus .l}", id),
		sprint("scrollbar .%sscroll -command {.%s yview}", id, id),
		sprint("pack .%sscroll -side left -fill y -in .m.%s", id, id),
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
	tk = load Tk Tk->PATH;
	tkclient= load Tkclient Tkclient->PATH;
	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	irc = load Irc Irc->PATH;
	irc->init(bufio);

	arg->init(args);
	arg->setusage(arg->progname()+" [-ds] [-h histsize] [path ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		'h' =>	readhistsize = string int arg->earg();
		's' =>	sflag++;
		* =>	fprint(fildes(2), "bad option\n");
			arg->usage();
		}
	args = arg->argv();

	sys->pctl(Sys->NEWPGRP, nil);
	plumbed = plumbmsg->init(1, nil, 0) >= 0;
	tkclient->init();
	(t, wmctl) = tkclient->toplevel(ctxt, "", "irc", Tkclient->Appl);

	cmd := chan of string;
	tk->namechan(t, cmd, "cmd");
	for(i := 0; i < len tkcmds; i++)
		tkcmd(tkcmds[i]);

	eventch = chan of (ref Srv, list of string);
	datach = chan of (ref Win, list of string);
	writererrch = chan[1] of (ref Win, string);
	usersch = chan of (ref Win, string);

	for(; args != nil; args = tl args) {
		(srv, err) := Srv.start(hd args);
		if(err != nil)
			fail("starting srv: "+err);
		servers = add(servers, srv);
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
			return;
		* =>
			tkclient->wmctl(t, menu);
		}

	bcmd := <-cmd =>
		r: string;
		(bcmd, r) = str->splitstrl(bcmd, " ");
		say(sprint("tk ui cmd: %q", bcmd));
		case bcmd {
		"find" or "findnext" =>
			if(curwin == nil)
				continue;
			start := "1.0";
			if(bcmd == "findnext") {
				nstart := tkcmd(sprint(".%s tag nextrange search 1.0", curwin.tkid));
				if(start != nil && start[0] != '!')
					(start, nil) = str->splitstrl(nstart, " ");
			}
			tkcmd(sprint(".%s tag remove search 1.0 end; update", curwin.tkid));
			pattern := tkcmd(".find get");
			if(pattern != nil) {
				index := tkcmd(sprint(".%s search [.find get] {%s +%dc}", curwin.tkid, start, len pattern));
				say("find, index: "+index);
				if(index != nil && index[0] != '!')
					tkcmd(sprint(".%s tag add search %s {%s +%dc}; .%s see %s; update", curwin.tkid, index, index, len pattern, curwin.tkid, index));
			}
		"snarf" =>
			s := selection();
			if(s != nil)
				writefile("/dev/snarf", s);
		"paste" =>
			(s, nil) := readfile("/dev/snarf");
			if(str->drop(s, "^\n") == nil) {
				tkcmd(".l insert insert '"+s);
				continue;
			}
			err := winwrite(curwin, s);
			if(err != nil) {
				warn("writing: "+err);
				tkwinwarn(curwin, "writing: "+err);
			}
		"plumb" =>
			if(curwin == nil)
				continue;
			s := selection();
			if(s != nil)
				plumbsend(s, sprint("%s/%s/", curwin.srv.path, curwin.id), "name", curwin.name);
		"nextwin" =>
			if(curwin != nil)
				windows[(curwin.listindex+1)%len windows].show();
		"prevwin" =>
			if(curwin != nil)
				windows[(curwin.listindex-1+len windows)%len windows].show();
		"lastwin" =>
			if(lastwin != nil)
				lastwin.show();
		"prevactivewin" =>
			off := 0;
			if(curwin != nil)
				off = curwin.listindex;
			which := array[] of {Highlight, Data, Meta};
		done:
			for(w := 0; w < len which; w++)
				for(i = len windows; i >= 0; i--)
					if(windows[(i+off)%len windows].state == which[w]) {
						windows[(i+off)%len windows].show();
						break done;
					}
		"nextactivewin" =>
			off := 0;
			if(curwin != nil)
				off = curwin.listindex;
			which := array[] of {Highlight, Data, Meta};
		done:
			for(w := 0; w < len which; w++)
				for(i = 0; i < len windows; i++)
					if(windows[(i+off)%len windows].state == which[w]) {
						windows[(i+off)%len windows].show();
						break done;
					}
		"clearwin" =>
			tkcmd(sprint(".%s delete 1.0 end; update", curwin.tkid));

		"say" =>
			line := tkcmd(".l get");
			if(line == nil)
				continue;
			tkcmd(".l delete 0 end; update");
			if(line[0] == '/' && !(len line > 2 && line[1] == '/')) {
				command(line[1:]);
			} else {
				say("say line");
				if(line[0] == '/')
					line = line[1:];
				err := winwrite(curwin, line);
				if(err != nil)
					tkwinwarn(curwin, "writing: "+err);
			}
		"complete" =>
			if(curwin == nil)
				continue;
			l := tkcmd(".l get");
			index := int tkcmd(".l index insert");
			say(sprint("l=%q index=%d", l, index));
			if(index == len l)
				index--;
			if(index < 0 || index > len l)
				continue;
			for(start := index; start > 0 && !str->in(l[start-1], " \t"); start--)
				;
			w := lowercase(l[start:index+1]);
			say(sprint("start=%d index=%d w=%q", start, index, w));
			for(j := 0; j < len curwin.users; j++) {
				u := lowercase(curwin.users[j]);
				if(len w < len u && w == u[:len w]) {
					suf := " ";
					if(start == 0)
						suf = ": ";
					tkcmd(sprint(".l delete %d %d; .l insert %d '%s", start, index+1, start, curwin.users[j]+suf));
					tkcmd("update");
					break;
				}
			}

		"winsel" =>
			say("winsel");
			index := int tkcmd(".targs curselection");
			windows[index].show();
		* =>
			print("%s\n", bcmd);
		}

	(srv, tokens) := <-eventch =>
		event := hd tokens;
		tokens = tl tokens;
		case event {
		"new" =>
			if(len tokens != 2) {
				warn(sprint("bad 'new' message"));
				continue;
			}
			id := hd tokens;
			name := hd tl tokens;
			srv.unopen = winadd(srv.unopen, ref (name, id));
			if(!sflag || id == "0") {
				(win, err) := Win.start(srv, id, name);
				if(err != nil)
					fail(err);
				addwindow(win);
			} else {
				for(i = 0; i < len windows; i++)
					if(windows[i].srv == srv && windows[i].id == "0")
						break;
				if(i < len windows)
					tkwinwrite(windows[i], sprint("new window: %s (%s)", name, id), "resp");
			}
			say(sprint("have new target, path=%s id=%s", srv.path, id));
		"del" =>
			say(sprint("del target %q", hd tokens));
			if((j := winindex(srv.open, ref (nil, hd tokens))) >= 0)
				srv.dead = winadd(srv.dead, srv.open[j]);
			srv.open = windel(srv.open, ref (nil, hd tokens));
			srv.unopen = windel(srv.unopen, ref (nil, hd tokens));
			
		"nick" =>
			say("new nick: "+hd tokens);
			srv.nick = hd tokens;
			srv.lnick = lowercase(srv.nick);
		"disconnected" =>
			say("disconnected");
		"connected" =>
			srv.nick = hd tokens;
			srv.lnick = lowercase(srv.nick);
			say("new nick: "+srv.nick);
			say("now connected");
		"connecting" =>
			say("connecting");
		}

	(win, lines) := <-datach =>
		if(lines == nil) {
			win.addline("eof\n", "warning");
			continue;
		}
		say(sprint("have %d lines, from path=%s name=%s", len lines, win.srv.path, win.name));
		lastvis := 1;
		yview := tkcmd(sprint(".%s yview", win.tkid));
		say("yview: "+yview);
		if(yview != nil && yview[0] != '!') {
			(nil, yview) = str->splitstrl(yview, " ");
			if(yview != nil) {
				yview = yview[1:];
				lastvis = real yview >= 0.95 || int yview >= 1;
			}
		}
		say("lastvis: "+string lastvis);
		nlines := len lines;
		for(; lines != nil; lines = tl lines) {
			m := hd lines;
			if(len m < 2)
				continue;	# should not happen
			tag := "data";
			if(m[:2] == "# ")
				tag = "meta";
			m = m[2:]+"\n";

			win.addline(uncrap(m), tag);
			hl := highlight(win.srv.lnick, lowercase(m));
			if(hl >= 0)
				tkcmd(sprint(".%s tag add hl {end -1c linestart +%dc} {end -1 linestart +%dc +%dc}", win.tkid, hl, hl, len win.srv.nick));
			if(nlines == 1 && win != curwin) {
				if(tag == "meta")
					win.setstatus(Meta);
				else if(!win.ischan || hl >= 0)
					win.setstatus(Highlight);
				else
					win.setstatus(Data);
			}
		}
		if(lastvis)
			tkcmd(sprint(".%s see {end -1c lineend}", win.tkid));
		tkcmd("update");

	(w, err) := <-writererrch =>
		tkwinwarn(w, "writing: "+err);
		warn("writing: "+err);

	(w, l) := <-usersch =>
		s: string;
		while(l != nil) {
			(s, l) = str->splitstrl(l, "\n");
			if(l != nil)
				l = l[1:];
			if(s == nil) {
				warn("empty user line");
				continue;
			}
			say(sprint("userline=%q", s));
			case s[0] {
			'+' =>	w.users = add(w.users, s[1:]);
			'-' =>	w.users = del(w.users, s[1:]);
			* =>	warn("bad user line: "+s);
			}
		}
	}
}

uncrap(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		2 =>	# introduces bold
			;
		3 =>	# introduces color (and 2-digit code)
			if(i+2 < len s && str->in(s[i+1], "0-9") && str->in(s[i+2], "0-9"))
				i += 2;
		* =>	r[len r] = s[i];
		}
	return r;
}

highlight(word, m: string): int
{
	if(len m < len word)
		return -1;
	word = lowercase(word);
	m = lowercase(m);
top:
	for(i := 0; i < len m-len word; i++) {
		k := i;
		j := 0;
		while(j < len word)
			if(m[k++] != word[j++])
				continue top;
		return i;
	}
	return -1;
}

command(line: string)
{
	(cmd, rem) := str->splitstrl(line, " ");
	if(curwin == nil && cmd != "addsrv" && cmd != "exit") {
		tkwarn("no window context");
		return;
	}

	err := "";
	case cmd {
	"close" =>
		delwindow(curwin);
	"exit" =>
		killgrp(sys->pctl(0, nil));
		exit;
	"addsrv" =>
		rem = str->drop(rem, " \t");
		say(sprint("adding server path=%q", rem));
		srv: ref Srv;
		(srv, err) = Srv.start(rem);
		if(err == nil)
			servers = add(servers, srv);
	"delsrv" =>
		srv := curwin.srv;
		for(i := 0; i < len windows;)
			if(windows[i].srv == srv)
				delwindow(windows[i]);
			else
				i++;
		servers = del(servers, srv);
	"addwin" =>
		rem = str->drop(rem, " \t");
		win: ref Win;
		srv := curwin.srv;
		(win, err) = Win.start(srv, rem, nil);
		if(err != nil)
			tkwarn("adding window: "+err);
		addwindow(win);
		say(sprint("have new target, path=%s id=%s", curwin.srv.path, rem));
	"windows" =>
		srv := curwin.srv;
		tksay("open windows:");
		for(i := 0; i < len srv.open; i++)
			tksay(sprint("\t%-15s (%s)", srv.open[i].t0, srv.open[i].t1));
		tksay("dead windows:");
		for(i = 0; i < len srv.dead; i++)
			tksay(sprint("\t%-15s (%s)", srv.dead[i].t0, srv.dead[i].t1));
		tksay("unopened windows:");
		for(i = 0; i < len srv.unopen; i++)
			tksay(sprint("\t%-15s (%s)", srv.unopen[i].t0, srv.unopen[i].t1));
	"away" =>
		for(i := 0; i < len servers; i++)
			if(fprint(servers[i].ctlfd, "%s", line) < 0)
				tkwarn(sprint("%s: %r", servers[i].path));
	"clearwin" =>
		tkcmd(sprint(".%s delete 1.0 end; update", curwin.tkid));
	* =>
		err = curwin.ctlwrite(line);
	}
	if(err != nil)
		tkwarn(err);
}

Srv.start(path: string): (ref Srv, string)
{
	eventfd := sys->open(path+"/event", Sys->OREAD);
	if(eventfd == nil)
		return (nil, sprint("open: %r"));
	ctlfd := sys->open(path+"/ctl", Sys->OWRITE);
	if(ctlfd == nil)
		return (nil, sprint("open: %r"));
	srv := ref Srv(string (lastsrvid++), path, ctlfd, eventfd, nil, nil,
		array[0] of ref (string, string), array[0] of ref (string, string), array[0] of ref (string, string));

	spawn eventreader(eventfd, srv);
	return (srv, nil);
}

eventreader(fd: ref Sys->FD, srv: ref Srv)
{
	b := bufio->fopen(fd, Sys->OREAD);
	if(b == nil)
		fail("bufio fopen: %r");
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

Win.start(srv: ref Srv, id, name: string): (ref Win, string)
{
	p := sprint("%s/%s/", srv.path, id);

	datafd := sys->open(p+"data", Sys->ORDWR);
	if(datafd == nil)
		return (nil, sprint("open: %r"));
	if(readhistsize != nil) {
		dir := sys->nulldir;
		dir.length = big readhistsize;
		if(sys->fwstat(datafd, dir) < 0)
			warn(sprint("writing history size: %r"));
	}

	if(name == nil) {
		err: string;
		(name, err) = readfile(p+"name");
		if(err != nil)
			return (nil, err);
	}
	usersfd := sys->open(p+"users", Sys->OREAD);
	if(usersfd == nil)
		return (nil, sprint("open: %r"));

	win := ref Win(srv, id, sprint("t-%s-%s", srv.id, id), name, -1, nil, datafd, 0, nil, 0, ischannel(name), chan[16] of string, array[0] of string);
	pidc := chan of int;
	spawn reader(pidc, datafd, win);
	spawn writer(pidc, datafd, win);
	spawn usersreader(pidc, usersfd, win);
	win.pids = <-pidc::<-pidc::<-pidc::win.pids;
	say("Win.start, done");
	return (win, nil);
}

reader(pidc: chan of int, fd: ref Sys->FD, win: ref Win)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		n := sys->read(fd, buf := array[8*1024] of byte, len buf);
		if(n == 0) {
			say("reader: eof");
			datach <-= (win, nil);
			break;
		}
		if(n < 0) {
			warn(sprint("read error: %r"));
			break;
		}
		say("reader: have data");
		(nil, lines) := sys->tokenize(string buf[:n], "\n");;
		datach <-= (win, lines);
	}
}

writer(pidc: chan of int, fd: ref Sys->FD, w: ref Win)
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

usersreader(pidc: chan of int, fd: ref Sys->FD, w: ref Win)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		n := sys->read(fd, d := array[1024] of byte, len d);
		if(n == 0)
			break;
		if(n < 0) {
			warn(sprint("reading users: %r"));
			break;
		}
		usersch <-= (w, string d[:n]);
	}
}

winwrite(w: ref Win, l: string): string
{
	alt {
	w.writec <-= l =>	return nil;
	* =>			return "too many writes queued, discarding line";
	}
}

Win.addline(w: self ref Win, l: string, tag: string)
{
	w.nlines++;
	if(w.nlines >= Maxlines)
		tkcmd(sprint(".%s delete 1.0 1.end", w.tkid));
	tkcmd(sprint(".%s insert end '%s", w.tkid, l));
	tkcmd(sprint(".%s tag add %s {end -1c -%dc} {end - 1c}", w.tkid, tag, len l));
}

Win.show(w: self ref Win)
{
	if(w == curwin)
		return;
	say("show");
	w.setstatus(None);
	if(curwin != nil)
		tkcmd(sprint("pack forget .m.%s", curwin.tkid));

	tkcmd(sprint("bind .l <Control-\\-> {.%s yview scroll -0.75 page}", w.tkid));
	tkcmd(sprint("bind .l <Control-=> {.%s yview scroll 0.75 page}", w.tkid));
	tkcmd(sprint("pack .m.%s -in .m.text -fill both -expand 1", w.tkid));
	lastwin = curwin;
	curwin = w;
	tkcmd(sprint(".targs selection clear 0 end; .targs selection set %d; .targs see %d; update", curwin.listindex, curwin.listindex));
}

Win.close(w: self ref Win)
{
	for(; w.pids != nil; w.pids = tl w.pids)
		kill(hd w.pids);
	tkcmd(sprint("destroy .%s; destroy .m.%s", w.tkid, w.tkid));
}

Win.ctlwrite(w: self ref Win, s: string): string
{
	if(w.ctlfd == nil)
		w.ctlfd = sys->open(sprint("%s/%s/ctl", w.srv.path, w.id), Sys->OWRITE);
	if(w.ctlfd == nil)
		return sprint("%r");
	else if(fprint(w.ctlfd, "%s", s) < 0)
		return sprint("%r");
	return nil;
}

Win.setstatus(w: self ref Win, s: int)
{
	if(s <= w.state && s != None)
		return;
	c := ' ';
	case w.state = s {
	Highlight =>	c = '=';
			plumbsend(nil, sprint("%s/%s/", w.srv.path, w.id), "highlight", w.name);
	Data =>		c = '+';
	Meta =>		c = '-';
	}
	ws := " ";
	if(w.id == "0")
		ws = "";
	tkcmd(sprint(".targs delete %d; .targs insert %d {%c%s%s}; update", w.listindex, w.listindex, c, ws, w.name));
}

placewindow(w: ref Win): int
{
	# windows are ordered by server, within a server the latest window at the end
	for(srvi := 0; srvi < len servers && servers[srvi] != w.srv; srvi++)
		;
	# walk through all windows, when we find a window of our or an earlier server, we stop
	for(i := len windows-1; i >= 0; i--)
		for(j := 0; j <= srvi; j++)
			if(windows[i].srv == servers[j])
				return i+1;
	return 0;
}

addwindow(w: ref Win)
{
	say("newwindow");
	w.listindex = placewindow(w);
	tail := windows[w.listindex:];
	windows = grow(windows, 1);
	windows[w.listindex] = w;
	windows[w.listindex+1:] = tail;
	for(i := w.listindex+1; i < len windows; i++)
		windows[i].listindex = i;
	tkcmd(sprint(".targs insert %d {}", w.listindex));
	w.setstatus(None);
	maketext(w.tkid);
	if(len windows == 1)
		w.show();
	w.srv.open = winadd(w.srv.open, ref (w.name, w.id));
	w.srv.unopen = windel(w.srv.unopen, ref (w.name, w.id));
}

delwindow(w: ref Win)
{
	say("delwindow");
	tkcmd(sprint(".targs delete %d; update", w.listindex));
	if(winindex(w.srv.open, ref (w.name, w.id)) >= 0)
		w.srv.unopen = winadd(w.srv.unopen, ref (w.name, w.id));
	w.srv.open = windel(w.srv.open, ref (w.name, w.id));
	w.srv.dead = windel(w.srv.dead, ref (w.name, w.id));
	windows = del(windows, w);
	for(i := w.listindex; i < len windows; i++)
		windows[i].listindex = i;
	w.close();
	if(curwin != w)
		return;
	if(len windows == 0)
		curwin = nil;
	else if(lastwin != nil && lastwin != w)
		lastwin.show();
	else {
		index := w.listindex;
		if(index >= len windows)
			index--;
		windows[index].show();
	}
}

winadd(a: array of ref (string, string), e: ref (string, string)): array of ref (string, string)
{
	if(winindex(a, e) < 0)
		a = add(a, e);
	return a;
}

windel(a: array of ref (string, string), e: ref (string, string)): array of ref (string, string)
{
	if((i := winindex(a, e)) >= 0) {
		a[i:] = a[i+1:];
		a = a[:len a-1];
	}
	return a;
}

winindex(a: array of ref (string, string), e: ref (string, string)): int
{
	for(i := 0; i < len a; i++)
		if(a[i].t1 == e.t1)
			return i;
	return -1;
}

selection(): string
{
	if(curwin == nil)
		return nil;
	return tkcmd(sprint(".%s get sel.first sel.last", curwin.tkid));
}

delselection()
{
	if(curwin != nil)
		tkcmd(sprint(".%s delete sel.first sel.last", curwin.tkid));
}

tkwinwrite(w: ref Win, s, tag: string)
{
	if(w != nil) {
		w.addline(s+"\n", tag);
		tkcmd(sprint(".%s see {end -1c lineend}; update", w.tkid));
	}
}

tkwinwarn(w: ref Win, s: string)
{
	tkwinwrite(w, s, "warning");
}

tkwarn(s: string)
{
	tkwinwrite(curwin, s, "warning");
}

tksay(s: string)
{
	tkwinwrite(curwin, s, "resp");
}

plumbsend(text, path, attrname, attrval: string)
{
	if(!plumbed)
		return;
	attrs := plumbmsg->attrs2string(ref Plumbmsg->Attr(attrname, attrval)::nil);
	msg := ref Msg("WmIrc", "", path, "text", attrs, array of byte text);
	msg.send();
}

writefile(p: string, s: string): string
{
	fd := sys->open(p, Sys->OWRITE);
	if(fd == nil)
		return sprint("open: %r");
	if(sys->write(fd, d := array of byte s, len d) != len d)
		return sprint("%r");
	return nil;
}

readfile(p: string): (string, string)
{
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return (nil, sprint("open: %r"));
	n := sys->readn(fd, buf := array[8*1024] of byte, len buf);
	if(n < 0)
		return (nil, sprint("read: %r"));
	return (string buf[:n], nil);
}

tkcmd(s: string): string
{
	r := tk->cmd(t, s);
	if(r != nil && r[0] == '!')
		warn(sprint("tkcmd: %q: %s", s, r));
	return r;
}

grow[T](a: array of T, n: int): array of T
{
	na := array[len a+n] of T;
	na[:] = a;
	return na;
}

add[T](a: array of T, e: T): array of T
{
	a = grow(a, 1);
	a[len a-1] = e;
	return a;
}

del[T](a: array of T, e: T): array of T
{
	for(i := 0; i < len a; i++)
		if(a[i] == e) {
			a[i:] = a[i+1:];
			a = a[:len a-1];
			break;
		}
	return a;
}

kill(pid: int)
{
	if((fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE)) != nil)
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
