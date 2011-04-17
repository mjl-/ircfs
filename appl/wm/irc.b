implement WmIrc;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "string.m";
	str: String;
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "daytime.m";
	dt: Daytime;
include "regex.m";
	regex: Regex;
	Re: import Regex;
include "plumbmsg.m";
	plumbmsg: Plumbmsg;
	Msg: import plumbmsg;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "keyboard.m";

Windowlinesmax: con 8*1024;

datac: chan of (ref Win.Irc, list of string);
eventc: chan of (ref Srv, list of string);
pongc: chan of (ref Srv, list of string);
usersc: chan of (ref Win.Irc, string);
newsrvc: chan of (ref Srv, string);
newwinc: chan of (int, (ref Win.Irc, string));
writererrc: chan of (ref Win.Irc, string);
button1 := 0;

# connection to an ircfs
lastsrvid := 0;		# unique id's
Srv: adt {
	id:	int;		# lastsrvid
	path:	string;	
	ctlfd,
	pongfd:	ref Sys->FD;
	eventb:	ref Iobuf;
	nick, lnick:	string;	# our name and lowercase
	eventpid:	int;
	win0:	cyclic ref Win.Irc;
	wins:	cyclic list of ref Win.Irc;		# includes win0
	unopen:	list of ref (string, int);	# name, id
	dead:	int;
	writec:	chan of (ref Win.Irc, ref Sys->FD, string);
	writepid:	int;

	# we keep reading the pong file, if no data comes in, ircfs isn't responding.
	# if nopong comes in, the server isn't responding.
	pongpid:	int;  # pid of pong reader
	lastpong:	int;  # time of last seen pong/nopong message
	nopong:		int;  # whether last message was a nopong
	noircfs:	int;  # whether we're missing messages from ircfs
	pongwatchpid: 	int;

	init:	fn(srvid: int, path: string): (ref Srv, string);
	addunopen:	fn(srv: self ref Srv, name: string, id: int);
	delunopen:	fn(srv: self ref Srv, id: int);
	haveopen:	fn(srv: self ref Srv, id: int): int;
	findwin:	fn(srv: self ref Srv, id: int): ref Win.Irc;
};

None, Meta, Delayed, Data, Highlight: con 1<<iota;	# Win.state

# window, an irc directory except for status window
Win: adt {
	name:	string;
	tkid:	string;
	listindex:	int;
	eof:	int;
	nlines:	int;		# lines in window
	state:	int;

	pick {
	Irc =>
		srv:	ref Srv;
		id:	int;
		ctlfd, datafd, usersfd:	ref Sys->FD;
		pids:	list of int;	# for reader, usersreader
		ischan:	int;
		users:	list of string;	# with case
	Status =>
	}

	init:	fn(srv: ref Srv, id: int, name: string): (ref Win.Irc, string);
	writetext:	fn(w: self ref Win, s: string): string;
	addline:	fn(w: self ref Win, l: string, tag: string);
	close:	fn(w: self ref Win);
	writectl:	fn(w: self ref Win, s: string): string;
	setstate:	fn(w: self ref Win, state: int);
	status:		fn(w: self ref Win): string;
	scroll:		fn(w: self ref Win);
	scrolled:	fn(w: self ref Win): int;
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
width := 800;
height := 600;
res: list of Re;

Pinginterval: con 60;	# seconds between ircfs pong and next ping
Noponginterval: con 5;	# seconds ircfs waits before sending nopong
Pongslack: con 5;	# seconds the pong/nopong event may be late before we start complaining
pongwatchc: chan of ref Srv;

WmIrc: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

tkcmds := array[] of {
	"frame .m",
	"frame .m.ctl",
	"frame .m.text",
	"frame .side",

	"button .plumb -text plumb -command {send cmd plumb; focus .l}",
	"button .mark -text {clear status} -command {send cmd mark; focus .l}",
	"entry .find",
	"bind .find <Key-\n> {send cmd find}",
	"bind .find <Control-n> {send cmd findnext}",
	"bind .find <Control-p> {send cmd findprev}",
	"bind .find <Control-t> {focus .l}",
	"bind .find <ButtonPress-1> +{send cmd b1down}",
	"bind .find <ButtonRelease-1> +{send cmd b1up}",
	"bind .find <ButtonRelease-2> {send cmd cut .find}",
	"bind .find <ButtonRelease-3> {send cmd paste .find}",
	"button .prev -text << -command {send cmd findprev}",
	"button .next -text >> -command {send cmd findnext}",
	"pack .plumb .mark -side left -in .m.ctl",
	"pack .next .prev -side right -in .m.ctl",
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
	"bind .l <ButtonPress-1> +{send cmd b1down}",
	"bind .l <ButtonRelease-1> +{send cmd b1up}",
	"bind .l <ButtonRelease-2> {send cmd cut .l}",
	"bind .l <ButtonRelease-3> {send cmd paste .l}",

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
	tkcmd(sprint("frame .m.%s", id));
	tkcmd(sprint("text .%s -wrap word -yscrollcommand {.%s-scroll set}", id, id));
	tkfont := tkcmd(sprint(".%s cget -font", id));
	cmds := array[] of {
		# without the font-part, the lmargin seems to be ignored...
		sprint(".%s tag configure meta -fg blue -font %s -lmargin2 6w", id, tkfont),
		sprint(".%s tag configure warning -fg red", id),
		sprint(".%s tag configure data -fg black -font %s -lmargin2 16w", id, tkfont),
		sprint(".%s tag configure hl -bg yellow", id),
		sprint(".%s tag configure search -bg orange", id),
		sprint(".%s tag configure status -fg green", id),
		sprint(".%s tag configure bold -underline 1", id),
		sprint("bind .%s <Control-f> {focus .find}", id),
		sprint("bind .%s <Control-t> {focus .l}", id),
		sprint("bind .%s <ButtonPress-1> +{send cmd b1down}", id),
		sprint("bind .%s <ButtonRelease-1> +{send cmd b1up}", id),
		sprint("bind .%s <ButtonRelease-2> {send cmd textcut %s}", id, id),
		sprint("bind .%s <ButtonRelease-3> {send cmd textpaste %s}", id, id),

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
	str = load String String->PATH;
	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	dt = load Daytime Daytime->PATH;
	regex = load Regex Regex->PATH;
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil)
		fail("no window context");

	sys->pctl(Sys->NEWPGRP, nil);

	arg->init(args);
	arg->setusage(arg->progname()+" [-ds] [-g width height] [-h histsize] [-r hlregex] [path ...]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>
			dflag++;
		'g' =>
			width = int arg->earg();
			height = int arg->earg();
		'h' =>
			readhistsize = big arg->earg();
		'r' =>
			(r, err) := regex->compile(arg->earg(), 0);
			if(err != nil)
				fail(err);
			res = r::res;
		's' =>
			sflag++;
		* =>
			arg->usage();
		}
	args = arg->argv();

	plumbed = plumbmsg->init(1, nil, 0) >= 0;
	(t, wmctl) = tkclient->toplevel(ctxt, "", "irc", Tkclient->Appl);

	tkcmdchan := chan of string;
	tk->namechan(t, tkcmdchan, "cmd");
	for(i := 0; i < len tkcmds; i++)
		tkcmd(tkcmds[i]);
	tkcmd(sprint(". configure -width %d -height %d", width, height));

	maketext("status");
	statuswin = ref Win.Status("status", "status", 0, 0, 0, None);
	lastwin = curwin = statuswin;
	fixwindows();
	tkwinwrite(statuswin, "status window", "meta");

	datac = chan of (ref Win.Irc, list of string);
	eventc = chan of (ref Srv, list of string);
	pongc = chan of (ref Srv, list of string);
	usersc = chan of (ref Win.Irc, string);
	writererrc = chan[1] of (ref Win.Irc, string);
	newsrvc = chan of (ref Srv, string);
	newwinc = chan of (int, (ref Win.Irc, string));
	pongwatchc = chan of ref Srv;

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd"::"ptr"::nil);

	for(; args != nil; args = tl args)
		spawn srvopen(lastsrvid++, hd args);

	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);

	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);

	s := <-t.ctxt.ctl or
	s = <-t.wreq or
	s = <-wmctl =>
		scrolled := array[len windows] of {* => 0};
		if(str->prefix("!", s))
			for(i = 0; i < len windows; i++)
				scrolled[i] = windows[i].scrolled();
		tkclient->wmctl(t, s);
		for(i = 0; i < len scrolled; i++)
			if(scrolled[i])
				windows[i].scroll();
		tkcmd("update");

	srv := <-pongwatchc =>
		say("pongwatch timeout");
		srv.pongwatchpid = -1;
		if(srv.dead)
			continue;
		tkwinwarn(srv.win0, sprint("no ircfs response for %d seconds", dt->now()-srv.lastpong));
		srv.win0.setstate(srv.win0.state|Delayed);
		tkcmd("update");
		pongwatch(srv, 5);
		srv.noircfs = 1;

	(srv, err) := <-newsrvc =>
		if(err != nil) {
			tkwarn(err);
			continue;
		}
		pidc := chan of int;
		spawn eventreader(pidc, srv);
		srv.eventpid = <-pidc;
		spawn pongreader(pidc, srv);
		srv.pongpid = <-pidc;
		spawn writer(pidc, srv);
		srv.writepid = <-pidc;
		servers = srv::servers;

	(show, (win, err)) := <-newwinc =>
		if(err != nil) {
			tkwarn(err);
			continue;
		}
		if(win.srv.dead)
			continue;
		win.state = None;
		pidc := chan of int;
		spawn reader(pidc, win.datafd, win);
		spawn usersreader(pidc, win.usersfd, win);
		win.pids = <-pidc::<-pidc::win.pids;
		addwindow(win);
		if(show)
			showwindow(win);

	cmd := <-tkcmdchan =>
		dotk(cmd);

	(ircwin, lines) := <-datac =>
		dodata(ircwin, lines);

	(srv, tokens) := <-eventc =>
		doevent(srv, tokens);

	(srv, tokens) := <-pongc =>
		dopong(srv, tokens);

	(ircwin, s) := <-usersc =>
		douser(ircwin, s);

	(w, err) := <-writererrc =>
		tkwinwarn(w, "writing: "+err);
	}
}

srvopen(srvid: int, s: string)
{
	newsrvc <-= Srv.init(srvid, s);
}

winopen(srv: ref Srv, id: int, name: string, show: int)
{
	newwinc <-= (show, Win.init(srv, id, name));
}

dotk(cmd: string)
{
	(word, rem) := str->splitstrl(cmd, " ");
	if(rem != nil)
		rem = rem[1:];
	say(sprint("tk ui cmd: %q", word));

	case word {
	"find" or
	"findnext" or
	"findprev" =>
		start := "end";
		if(word != "find") {
			# there should be only one range
			nstart := tkcmd(sprint(".%s tag nextrange search 1.0", curwin.tkid));
			if(nstart != nil && nstart[0] != '!')
				(start, nil) = str->splitstrl(nstart, " ");
		}
		tkcmd(sprint(".%s tag remove search 1.0 end", curwin.tkid));
		pattern := tkget(".find get");
		if(pattern != nil) {
			opt := "";
			if(word != "findnext")
				opt = "-backwards";
			else if(start != "end")
				start = sprint("{%s +%dc}", start, len pattern);
			say(sprint(".%s search %s [.find get] %s", curwin.tkid, opt, start));
			index := tkcmd(sprint(".%s search %s [.find get] %s", curwin.tkid, opt, start));
			say("find, index: "+index);
			if(index != nil && index[0] != '!')
				tkcmd(sprint(".%s tag add search %s {%s +%dc}; .%s see %s",
					curwin.tkid, index, index, len pattern, curwin.tkid, index));
		}
		tkcmd("update");

	"b1down" =>
		button1 = 1;
	"b1up" =>
		button1 = 0;

	"cut" =>
		if(1 || button1)
			tkcut(rem);

	"paste" =>
		if(1 || button1)
			tkpaste(rem);

	"textcut" =>
		# note: double click produces "b1down b1up" and after release b1up again.  the second b1down is lost...
		if(1 || button1) {
			s := selection(rem);
			if(s != nil) {
				tkclient->snarfput(s);
				tkcmd(sprint(".%s delete sel.first sel.last", rem));
				tkcmd("update");
			}
		}

	"textpaste" =>
		if(1 || button1) {
			s := tkclient->snarfget();
			tk->cmd(t, sprint(".%s delete sel.first sel.last", rem)); # fails when nothing selected
			tkcmd(sprint(".%s insert insert %s; .%s tag add sel insert-%dchars insert", rem, tk->quote(s), rem, len s));
			tkcmd("update");
		}

	"plumb" =>
		s := selection(curwin.tkid);
		if(s != nil)
			curwin.plumbsend(s, "name", curwin.name);

	"mark" =>
		for(i := 0; i < len windows; i++)
			windows[i].setstate(None);
		fixwinsel(curwin.listindex);

	"nextwin" =>
		showwindow(windows[(curwin.listindex+1)%len windows]);

	"prevwin" =>
		showwindow(windows[(curwin.listindex-1+len windows)%len windows]);

	"lastwin" =>
		showwindow(lastwin);

	"prevactivewin" =>
		off := curwin.listindex;
		which := array[] of {Highlight, Data, Delayed, Meta};
		for(w := 0; w < len which; w++)
			for(i := len windows; i >= 0; i--)
				if(windows[v := (i+off)%len windows].state & which[w])
					return showwindow(windows[v]);

	"nextactivewin" =>
		off := curwin.listindex;
		which := array[] of {Highlight, Data, Delayed, Meta};
		for(w := 0; w < len which; w++)
			for(i := 0; i < len windows; i++)
				if(windows[v := (i+off)%len windows].state & which[w])
					return showwindow(windows[v]);

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
			#say("say line");
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
			if(w == nil)
				return;

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

	scroll := win.scrolled();
	nlines := len lines;
	for(; lines != nil; lines = tl lines) {
		m := hd lines;
		if(len m < 2) {
			tkstatuswarn(sprint("bad data line: %q", m));
			continue;
		}
		tag := "data";
		state := Data;
		nostatechange := m[:2] == "! ";
		case m[:2] {
		"# " or
		"! " =>
			tag = "meta";
			state = Meta;
		"- " =>
			state = None;
		}

		(mm, bolds) := uncrap(m[2:]);
		m = mm+"\n";
		win.addline(m, tag);

		for(; bolds != nil; bolds = tl bolds) {
			(start, end) := *hd bolds;
			tkcmd(sprint(".%s tag add bold {end -1c linestart +%dc} {end -1 linestart +%dc}", win.tkid, start, end));
		}

		hl := matches(win.srv.lnick, lowercase(m));
		havehl := hl != nil;
		for(; hl != nil; hl = tl hl) {
			(s, e) := *hd hl;
			tkcmd(sprint(".%s tag add hl {end -1c linestart +%dc} {end -1 linestart +%dc}", win.tkid, s, e));
		}

		# at startup, we read a backlog.  these lines will be sent many lines in one read.
		# during normal operation we typically get one line per read.
		# this is a simple heuristic to start without all windows highlighted...
		if(nlines == 1 && win != curwin && !nostatechange) {
			if(state == Data && (!win.ischan || havehl))
				state |= Highlight;
			win.setstate(win.state|state);
		}
	}
	if(scroll)
		win.scroll();
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

		id := int hd tokens;
		name := hd tl tokens;
		if(srv.haveopen(id)) {
			tkstatuswarn(sprint("new window, but already present: %q (%d)", name, id));
			return;
		}
		srv.addunopen(name, id);
		if(!sflag || id == 0) {
			srv.delunopen(id);
			spawn winopen(srv, id, name, 0);
		} else if(srv.win0 != nil) {
			tkwinwrite(srv.win0, sprint("new window: %q (%d)", name, id), "status");
			tkcmd("update");
		}
		say(sprint("have new target, path=%q id=%d", srv.path, id));

	"del" =>
		id := int hd tokens;
		say(sprint("del target %d", id));
		srv.delunopen(id);
		w := srv.findwin(id);
		if(w != nil)
			delwindow(w);

	"nick" =>
		srv.nick = hd tokens;
		say(sprint("new nick: %q", srv.nick));
		srv.lnick = lowercase(srv.nick);

	"disconnected" =>
		say("disconnected");
		tkstatuswarn(sprint("disconnected: %q", srv.path));
		kill(srv.pongwatchpid);
		srv.pongwatchpid = -1;

	"connected" =>
		srv.nick = hd tokens;
		srv.lnick = lowercase(srv.nick);
		tkstatuswarn(sprint("connected %q: %q", srv.path, srv.nick));
		pongwatch(srv, Pinginterval+Noponginterval+Pongslack);

	"connecting" =>
		tkstatuswarn(sprint("connecting: %q", srv.path));
	}
}

dopong(srv: ref Srv, tokens: list of string)
{
	event := hd tokens;
	tokens = tl tokens;
	
	if(srv.noircfs) {
		tkwinwrite(srv.win0, sprint("have ircfs response again, after %d seconds", dt->now()-srv.lastpong), "warning");
		srv.win0.setstate(srv.win0.state & ~Delayed);
		tkcmd("update");
		srv.noircfs = 0;
	}
	case event {
	"pong" =>
		if(srv.nopong) {
			nsecs := 0;
			if(len tokens == 1)
				nsecs = int hd tokens;
			tkwinwrite(srv.win0, sprint("have irc server response again, after %d seconds", nsecs), "warning");
			srv.win0.setstate(srv.win0.state & ~Delayed);
			tkcmd("update");
			srv.nopong = 0;
		}
		srv.lastpong = dt->now();
		pongwatch(srv, Pinginterval+Noponginterval+Pongslack);

	"nopong" =>
		srv.lastpong = dt->now();
		nsecs := 0;
		if(len tokens == 1)
			nsecs = int hd tokens;
		tkwinwrite(srv.win0, sprint("no response from irc server for %d seconds", nsecs), "warning");
		srv.win0.setstate(srv.win0.state|Delayed);
		tkcmd("update");
		srv.nopong = 1;
		srv.noircfs = 0;
		pongwatch(srv, Noponginterval+Pongslack);
	* =>
		warn(sprint("unknown pong file message: %s", str->quoted(tokens)));
	}
}

pongwatch(srv: ref Srv, nsecs: int)
{
	kill(srv.pongwatchpid);
	say(sprint("pongwatch, reporting in %d seconds", nsecs));
	spawn pongwatcher(srv, nsecs, pidc := chan of int);
	srv.pongwatchpid = <-pidc;
}

pongwatcher(srv: ref Srv, nsecs: int, pidc: chan of int)
{
	pidc <-= pid();
	sys->sleep(nsecs*1000);
	pongwatchc <-= srv;
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
		#say(sprint("userline=%q", l));
		user := l[1:];
		case l[0] {
		'+' =>	w.users = user::w.users;
			if(!w.ischan) {
				w.name = user;
				drawstate(w);
			}
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
	if(cmd == "win") {
		if(rem != nil)
			rem = rem[1:];
		return wincmd(rem);
	}

	err := curwin.writectl(line);
	if(err != nil)
		tkwarn(err);
}

wincmd(line: string)
{
	(cmd, rem) := str->splitstrl(line, " ");
	case cmd {
	"add" =>
		rem = str->drop(rem, " \t");
		say(sprint("opening server %q", rem));
		spawn srvopen(lastsrvid++, rem);
		return;

	"exit" or
	"quit" =>
		killgrp(pid());
		exit;

	"clear" =>
		tkcmd(sprint(".%s delete 1.0 end; update", curwin.tkid));
		return;

	"away" =>
		for(l := servers; l != nil; l = tl l)
			if((s := hd l) != nil && s.wins != nil)
				(hd s.wins).writectl(line);
		return;
	}

	ircwin: ref Win.Irc;
	pick win := curwin {
	Status =>	return tkwarn("not an irc window");
	Irc =>		ircwin = win;
	}

	err: string;
	case cmd {
	"del" =>
		srv := ircwin.srv;
		srv.dead = 1;
		for(wl := srv.wins; wl != nil; wl = tl wl)
			(hd wl).close();
		servers = del(srv, servers);
		kill(srv.eventpid);
		kill(srv.pongpid);
		curwin = lastwin;
		pick win := lastwin {
		Irc =>
			if(win.srv == srv)
				curwin = lastwin = statuswin;
		}
		fixwindows();

	"close" =>
		if(curwin == ircwin.srv.win0)
			err = "cannot remove irc status window";
		else
			delwindow(ircwin);

	"open" =>
		rem = str->drop(rem, " \t");
		id := int rem;
		if(ircwin.srv.haveopen(id))
			err = "window already open";
		if(err == nil) {
			spawn winopen(ircwin.srv, id, nil, 1);
			say(sprint("winopen spawned for id %d", id));
		}

	"windows" =>
		tkstatus("open:");
		for(wl := rev(ircwin.srv.wins); wl != nil; wl = tl wl)
			tkstatus(sprint("\t%-15s (%d)", (hd wl).name, (hd wl).id));
		tkstatus("not open:");
		for(l := ircwin.srv.unopen; l != nil; l = tl l)
			tkstatus(sprint("\t%-15s (%d)", (hd l).t0, (hd l).t1));

	* =>
		err = "unknown command";
	}
	if(err != nil)
		tkwarn(err);
}

Srv.init(srvid: int, path: string): (ref Srv, string)
{
	eventb := bufio->open(path+"/event", Sys->OREAD);
	if(eventb == nil)
		return (nil, sprint("open: %r"));

	ctlfd := sys->open(path+"/ctl", Sys->OWRITE);
	if(ctlfd == nil)
		return (nil, sprint("open: %r"));

	pongfd := sys->open(path+"/pong", Sys->OREAD);
	if(pongfd == nil)
		return (nil, sprint("open: %r"));

	srv := ref Srv(srvid, path, ctlfd, pongfd, eventb, nil, nil, 0, nil, nil, nil, 0, chan[8] of (ref Win.Irc, ref Sys->FD, string), -1, -1, dt->now(), 0, 0, -1);
	return (srv, nil);
}

Srv.addunopen(srv: self ref Srv, name: string, id: int)
{
	srv.delunopen(id);
	srv.unopen = ref (name, id)::srv.unopen;
}

Srv.delunopen(srv: self ref Srv, id: int)
{
	unopen: list of ref (string, int);
	for(; srv.unopen != nil; srv.unopen = tl srv.unopen)
		if((hd srv.unopen).t1 != id)
			unopen = hd srv.unopen::unopen;
	srv.unopen = rev(unopen);
}

Srv.haveopen(srv: self ref Srv, id: int): int
{
	return srv.findwin(id) != nil;
}

Srv.findwin(srv: self ref Srv, id: int): ref Win.Irc
{
	for(wl := srv.wins; wl != nil; wl = tl wl)
		if((hd wl).id == id)
			return hd wl;
	return nil;
}

eventreader(pidc: chan of int, srv: ref Srv)
{
	pidc <-= pid();
	for(;;) {
		l := srv.eventb.gets('\n');
		if(l == nil) {
			warn(sprint("eventreader eof/error: %r"));
			break;
		}
		if(l[len l-1] == '\n')
			l = l[:len l-1];
		#say(sprint("have event"));
		(nil, tokens) := sys->tokenize(l, " ");
		eventc <-= (srv, tokens);
	}
}

pongreader(pidc: chan of int, srv: ref Srv)
{
	pidc <-= pid();
	buf := array[128] of byte;
	for(;;) {
		n := sys->read(srv.pongfd, buf, len buf);
		if(n == 0) {
			pongc <-= (srv, nil);
			break;
		}
		if(n < 0) {
			warn(sprint("read error: %r"));
			break;
		}
		l := sys->tokenize(string buf[:n], "\n").t1;
		for(; l != nil; l = tl l)
			pongc <-= (srv, sys->tokenize(hd l, " ").t1);
	}
}

writer(pidc: chan of int, srv: ref Srv)
{
	pidc <-= pid();
	for(;;) {
		(w, fd, s) := <-srv.writec;
		if(s == nil)
			break;
		n := sys->write(fd, d := array of byte s, len d);
		if(n != len d)
			writererrc <-= (w, sys->sprint("%r"));
	}
}


Win.init(srv: ref Srv, id: int, name: string): (ref Win.Irc, string)
{
	p := sprint("%s/%d", srv.path, id);

	datafd := sys->open(p+"/data", Sys->ORDWR);
	if(datafd == nil)
		return (nil, sprint("open: %r"));
	if(readhistsize >= big 0) {
		dir := sys->nulldir;
		dir.length = readhistsize;
		if(sys->fwstat(datafd, dir) < 0)
			tkstatuswarn(sprint("set history size: %r"));
	}
	ctlfd := sys->open(p+"/ctl", Sys->OWRITE);
	if(ctlfd == nil)
		return (nil, sprint("open: %r"));

	if(name == nil) {
		err: string;
		(name, err) = readfile(p+"/name");
		if(err != nil)
			return (nil, err);
	}
	usersfd := sys->open(p+"/users", Sys->OREAD);
	if(usersfd == nil)
		return (nil, sprint("open: %r"));

	tkid := sprint("t-%d-%d", srv.id, id);
	win := ref Win.Irc(name, tkid, -1, 0, 0, None, srv, id, ctlfd, datafd, usersfd, nil, ischannel(name), nil);
	return (win, nil);
}

reader(pidc: chan of int, fd: ref Sys->FD, win: ref Win.Irc)
{
	pidc <-= pid();
	buf := array[Sys->ATOMICIO] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n == 0) {
			datac <-= (win, nil);
			break;
		}
		if(n < 0) {
			warn(sprint("read error: %r"));
			break;
		}
		(nil, lines) := sys->tokenize(string buf[:n], "\n");
		datac <-= (win, lines);
	}
}

usersreader(pidc: chan of int, fd: ref Sys->FD, w: ref Win.Irc)
{
	pidc <-= pid();
	d := array[1024] of byte;
	for(;;) {
		n := sys->read(fd, d, len d);
		if(n == 0)
			break;
		if(n < 0) {
			warn(sprint("reading users: %r"));
			break;
		}
		usersc <-= (w, string d[:n]);
	}
}

writefd(w: ref Win.Irc, fd: ref Sys->FD, s: string): string
{
	alt {
	w.srv.writec <-= (w, fd, s) =>
		return nil;
	* =>
		return "too many writes queued, discarding line";
	}
}

Win.writetext(ww: self ref Win, s: string): string
{
	pick w := ww {
	Irc =>		return writefd(w, w.datafd, s);
	Status =>	return "bug: no data for status window";
	}
}

Win.writectl(ww: self ref Win, s: string): string
{
	pick w := ww {
	Irc =>		return writefd(w, w.ctlfd, s);
	Status =>	return "bug: no ctl's for status window";
	}
}

Win.addline(w: self ref Win, l: string, tag: string)
{
	if(w.nlines >= Windowlinesmax)
		tkcmd(sprint(".%s delete 1.0 2.0", w.tkid));
	else
		w.nlines++;

	tkcmd(sprint(".%s insert end '%s", w.tkid, l));
	tkcmd(sprint(".%s tag add %s {end -1c -%dc} {end -1c}", w.tkid, tag, len l));
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

Win.setstate(w: self ref Win, st: int)
{
	if(w.state == st)
		return;

	if(st & Highlight && (w.state & Highlight) == 0)
		w.plumbsend(nil, "highlight", w.name);
	w.state = st;
	drawstate(w);
}

Win.status(w: self ref Win): string
{
	c := " ";
	if(w.state & Highlight) c = "=";
	else if(w.state & Data) c = "+";
	else if(w.state & Delayed) c = "~";
	else if(w.state & Meta) c = "-";

	ws := "";
	pick ww := w {
	Irc =>
		if(ww.id != 0)
			ws = " ";
	}
	return c+ws+w.name;
}

drawstate(w: ref Win)
{
	tkcmd(sprint(".targs delete %d; .targs insert %d {%s}", w.listindex, w.listindex, w.status()));
}

Win.scroll(w: self ref Win)
{
	tkcmd(sprint(".%s scan mark 0 0; .%s scan dragto -10000 -10000", w.tkid, w.tkid));
}

Win.scrolled(w: self ref Win): int
{
	return tkcmd(sprint(".%s dlineinfo {end -1c linestart}", w.tkid)) != nil;
}

Win.plumbsend(w: self ref Win, text, key, val: string)
{
	if(!plumbed)
		return;
	path := w.name;
	pick ircwin := w {
	Irc =>
		path = sprint("%s/%d/", ircwin.srv.path, ircwin.id);
	}
	attrs := plumbmsg->attrs2string(ref Plumbmsg->Attr(key, val)::nil);
	msg := ref Msg("WmIrc", "", path, "text", attrs, array of byte text);
	msg.send();
}

showwindow(w: ref Win)
{
	tkcmd(sprint("pack forget .m.%s", curwin.tkid));

	tkcmd(sprint("bind .l <Key-%c> {.%s yview scroll -0.75 page}", Keyboard->Pgup, w.tkid));
	tkcmd(sprint("bind .l <Key-%c> {.%s yview scroll 0.75 page}", Keyboard->Pgdown, w.tkid));
	tkcmd(sprint("bind .l <Key-%c> {.%s see 1.0}", Keyboard->Home, w.tkid));
	tkcmd(sprint("bind .l <Key-%c> {.%s scan mark 0 0; .%s scan dragto -10000 -10000}", Keyboard->End, w.tkid, w.tkid));
	tkcmd(sprint("pack .m.%s -in .m.text -fill both -expand 1", w.tkid));
	w.scroll();

	w.setstate(None);
	tkcmd(sprint(".targs selection clear 0 end; .targs selection set %d; .targs see %d; update", w.listindex, w.listindex));
	lastwin = curwin;
	curwin = w;
}

fixwinsel(i: int)
{
	tkcmd(sprint(".targs selection set %d; .targs see %d; update", i, i));
}

winge(aa, bb: ref Win): int
{
	pick a := aa {
	Irc =>
		pick b := bb {
		Irc =>
			if(a.srv.id != b.srv.id)
				return a.srv.id >= b.srv.id;
			return a.id >= b.id;
		}
	}
	raise "bad params for winge";
}

l2awin(l: list of ref Win.Irc): array of ref Win
{
	a := array[len l] of ref Win;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

fixwindows()
{
	nwins := 1;
	for(s := servers; s != nil; s = tl s)
		nwins += len (hd s).wins;
	wins := array[nwins] of ref Win;
	wins[0] = statuswin;
	o := 1;
	for(l := servers; l != nil; l = tl l) {
		wins[o:] = l2awin((hd l).wins);
		o += len (hd l).wins;
	}
	sort(wins[1:], winge);
	
	useindex := -1;
	for(i := 0; i < len wins; i++) {
		wins[i].listindex = i;
		if(wins[i] == curwin || wins[i] == lastwin && useindex < 0)
			useindex = i;
	}
	if(useindex < 0)
		useindex = 0;

	windows = wins;
	tkcmd(sprint(".targs delete 0 end"));
	for(i = 0; i < len windows; i++) {
		w := windows[i];
		tkcmd(sprint(".targs insert %d {%s}", w.listindex, w.status()));
	}

	fixwinsel(useindex);
	showwindow(windows[useindex]);
}

addwindow(w: ref Win.Irc)
{
	maketext(w.tkid);
	w.srv.delunopen(w.id);
	w.srv.wins = w::w.srv.wins;

	if(w.id == 0)
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

selection(w: string): string
{
	return tkget(sprint(".%s get sel.first sel.last", w));
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

tkcut(w: string)
{
	if(!int tkcmd(w+" selection present"))
		return;

	start := int tkcmd(w+" index sel.first");
	end := int tkcmd(w+" index sel.last");
	v := tkcmd(w+" get");
	if(start >= 0 && start < len v && end >= 0 && end <= len v && start < end) {
		tkclient->snarfput(v[start:end]);
		tkcmd(sprint("%s delete sel.first sel.last; %s selection clear", w, w));
		tkcmd("update");
	}
}

tkpaste(w: string)
{
	new := tkclient->snarfget();
	start := int tkcmd(w+" index insert");
	if(int tkcmd(w+" selection present")) {
		start = int tkcmd(w+" index sel.first");
		end := int tkcmd(w+" index sel.last");
		tkcmd(sprint("%s delete %d %d", w, start, end));
	}
	tkcmd(sprint("%s insert %d %s; %s selection range %d %d", w, start, tk->quote(new), w, start, start+len new));
	tkcmd("update");
}

substr(sub, s: string): int
{
	last := len s-len sub;
	for(i := 0; i <= last; i++)
		if(str->prefix(sub, s[i:]))
			return i;
	return -1;
}

matches(sub: string, s: string): list of ref (int, int)
{
	hl := substr(sub, s);
	if(hl >= 0)
		l := ref (hl, hl+len sub)::nil;
	for(r := res; r != nil; r = tl r) {
		a := regex->execute(hd r, s);
		for(i := 0; i < len a; i++)
			l = ref a[i]::l;
	}
	return l;
}

taketl(s, cl: string): string
{
	for(i := len s; i > 0 && str->in(s[i-1], cl); i--)
		;
	return s[i:];
}

lowercase(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		case s[i] {
		'A' to 'Z' =>
			c = s[i]+('a'-'A');
		'[' =>	c = '{';
		']' =>	c = '}';
		'\\' =>	c = '|';
		'~' =>	c = '^';
		}
		r[i] = c;
	}
	return r;
}

ischannel(s: string): int
{
	return s != nil && !str->in(s[0], "a-zA-Z[\\]^_`{|}");
}

del[T](e: T, l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		if(hd l != e)
			r = hd l::r;
	return rev(r);
}

sort[T](a: array of T, ge: ref fn(a, b: T): int)
{
	for(i := 1; i < len a; i++) {
		tmp := a[i];
		for(j := i; j > 0 && ge(a[j-1], tmp); j--)
			a[j] = a[j-1];
		a[j] = tmp;
	}
}

rev[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l::r;
	return r;
}

pid(): int
{
	return sys->pctl(0, nil);
}

progctl(pid: int, s: string)
{
	sys->fprint(sys->open(sprint("/prog/%d/ctl", pid), sys->OWRITE), "%s", s);
}

kill(pid: int)
{
	if(pid >= 0)
		progctl(pid, "kill");
}

killgrp(pid: int)
{
	if(pid >= 0)
		progctl(pid, "killgrp");
}

say(s: string)
{
	if(dflag)
		warn(s);
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
