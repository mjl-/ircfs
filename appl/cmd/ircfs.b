implement Ircfs;

include "sys.m";
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
include "styx.m";
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
include "daytime.m";
include "lists.m";
include "irc.m";

sys: Sys;
str: String;
styx: Styx;
styxservers: Styxservers;
daytime: Daytime;
lists: Lists;
irc: Irc;

sprint: import sys;
Styxserver, Fid, Navigator, Navop: import styxservers;
lowercase, ischannel, Ircc, Timsg, Rimsg, From: import irc;
reverse: import lists;

Etarget: 	con "no such target";
Edead:		con "file closed";
Enocon:		con "not connected";
Estatus:	con "invalid on status file";
Enotchan:	con "only works on channel";
Enotfound, Enotdir: import Styxservers;

Histmax:	con 16*1024;
Histdefault:	con 6*1024;

Disconnected, Connecting, Connected: con iota;

Dflag, dflag: int;
logpath: string;
netname: string;
lastnick, lastaddr: string;
state := Disconnected;
starttime: int;

Qroot, Qrootctl, Qevent, Qraw, Qnick, Qdir, Qctl, Qname, Qusers, Qdata: con iota;
files := array[] of {
	(Qroot,		".",	Sys->DMDIR|8r555),

	(Qrootctl,	"ctl",	8r222),
	(Qevent,	"event",8r444),
	(Qraw,		"raw",	8r666),
	(Qnick,		"nick",	8r444),

	(Qdir, 		"",	Sys->DMDIR|8r555),
	(Qctl,		"ctl",	8r222),
	(Qname,		"name",	8r444),
	(Qusers,	"users",8r444),
	(Qdata,		"data",	8r666),
};

lastid := 0;
Target: adt {
	id:	int;
	name, lname:	string;
	ischan:	int;
	logfd:	ref Sys->FD;
	data, users:	array of ref Fidfile;
	hist:	array of array of byte;
	histlen:	int;
	begin, end:	int;
	joined, newjoined:	array of string;
	dead:	int;
	opens:	int;
	prevaway:	string;
	mtime:	int;

	new:	fn(name: string): ref Target;
	write:	fn(f: self ref Target, s: string);
	putdata:	fn(f: self ref Target, s: string);
	shutdown:	fn(f: self ref Target);
};

Fidfile: adt {
	fid:	ref Fid;
	histoff:	int;
	reads:	array of ref Tmsg.Read;

	a:	array of array of byte;

	new:		fn(fid: ref Fid, t: ref Target): ref Fidfile;
	write:	fn(f: self ref Fidfile, s: string);
	putdata:	fn(f: self ref Fidfile, s: string);
	putread:	fn(f: self ref Fidfile, m: ref Tmsg.Read);
	styxop:		fn(f: self ref Fidfile, t: ref Target): ref Rmsg.Read;
	flushop:	fn(f: self ref Fidfile, tag: int): int;
};
rawfile := array[0] of ref Fidfile;
eventfile := array[0] of ref Fidfile;

ic: ref Ircc;
srv: ref Styxserver;
targets := array[0] of ref Target;
status: ref Target;
ircinch: chan of (ref Rimsg, string, string);
ircoutch: chan of array of byte;
ircerrch: chan of string;
daych: chan of int;

readerpid := writerpid := -1;

Ircfs: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	styxservers->init(styx);
	daytime = load Daytime Daytime->PATH;
	lists = load Lists Lists->PATH;
	irc = load Irc Irc->PATH;
	irc->init(bufio);

	sys->pctl(Sys->NEWPGRP, nil);

	arg->init(args);
	arg->setusage(arg->progname()+" [-Dd] [-a addr] [-n nick] [-l logpath] netname");
	while((c := arg->opt()) != 0)
		case c {
		'a' =>	lastaddr = arg->earg();
		'n' =>	lastnick = arg->earg();
		'l' =>	logpath = arg->earg();
			if(logpath != nil && logpath[len logpath-1] != '/')
				logpath += "/";
		'D' =>	Dflag++;
			styxservers->traceset(Dflag);
		'd' =>	dflag++;
		* =>	sys->fprint(sys->fildes(2), "bad option\n");
			arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	netname = hd args;

	status = gettarget(sprint("(%s)", netname));
	starttime = daytime->now();

	ircinch = chan of (ref Rimsg, string, string);
	ircoutch = chan[16] of array of byte;
	ircerrch = chan of string;
	daych = chan of int;

	spawn dayticker();

	navch := chan of ref Navop;
	spawn navigator(navch);

	nav := Navigator.new(navch);
	msgc: chan of ref Tmsg;
	(msgc, srv) = Styxserver.new(sys->fildes(0), nav, big Qroot);

	for(;;) alt {
	<-daych =>
		for(i := 0; i < len targets; i++)
			if(!targets[i].dead)
				targets[i].write("# day changed");

	(m, line, err) := <-ircinch =>
		doirc(m, line, err);

	err := <-ircerrch =>
		status.write("# irc connection error: "+err+"\n");
		disconnect();

	gm := <-msgc =>
		if(gm == nil)
			break;
		pick m := gm {
		Readerror =>
			warn("read error: "+m.error);
			break;
		}
		dostyx(gm);
	}
}

dayticker()
{
	for(;;) {
		tm := daytime->local(daytime->now());
		secs := 24*3600-3*60 - tm.hour*3600-tm.min*60;
		if(secs > 0)
			sys->sleep(1000*secs);
		tm = daytime->local(daytime->now());
		secs = 24*3600 - tm.hour*3600-tm.min*60;
		sys->sleep(1000*secs);
		daych <-= 1;
	}
}

doirc(m: ref Rimsg, line, err: string)
{
	if(err != nil) {
		status.write(sprint("# bad irc message: %s (%s)\n", stripnewline(line), err));
		return;
	}
	writefile(rawfile, ">>> "+line);

	pick mm := m {
	Ping =>
		err = writemsg(ref Timsg.Pong(mm.who, mm.m));
		if(err != nil)
			warn("writing pong: "+err);

	Notice =>
		t := findtargetname(mm.where);
		if(t == nil)
			t = status;
		from := "";
		if(mm.f != nil)
			from = m.f.nick;
		t.write(sprint("# %s %8s: %s\n", stamp(), from, mm.m));

	Privmsg =>
		server := nick := "";
		if(mm.f != nil) {
			nick = m.f.nick;
			server = mm.f.server;
		}
		s := mm.m;
		action := "\u0001ACTION ";
		if(len s > len action && s[:len action] == action && s[len s-1] == 16r01)
			s = sprint("%s *%s %s", stamp(), nick, s[len action:len s-1]);
		else
			s = sprint("%s %8s: %s", stamp(), nick, s);
		targ := mm.where;
		if(lowercase(mm.where) == ic.lnick)
			targ = nick;
		dwrite(targ, s);

	Nick =>
		if(ic.fromself(mm.f)) {
			lastnick = ic.nick = mm.name;
			ic.lnick = lowercase(ic.nick);
			mwriteall(sprint("%s you are now known as %s", stamp(), ic.nick));
			writefile(eventfile, sprint("nick %s\n", ic.nick));
		} else {
			lnick := lowercase(mm.f.nick);
			said := 0;
			for(i := 0; i < len targets; i++) {
				t := targets[i];
				if(hasnick(t.joined, lnick) || t.lname == lnick) {
					t.joined = delnick(t.joined, lnick);
					t.joined = addnick(t.joined, mm.name);
					writefile(t.users, sprint("+%s\n-%s\n", mm.name, mm.f.nick));
					mwrite(t.name, sprint("%s %s is now known as %s", stamp(), mm.f.nick, mm.name));
					said++;
				}
				if(t.lname == lnick) {
					t.name = mm.name;
					t.lname = lowercase(t.name);
				}
			}
			if(!said)
				mwrite(mm.name, sprint("%s %s is now known as %s", stamp(), mm.f.nick, mm.name));
		}
	Mode =>
		modes := "";
		for(l := mm.modes; l != nil; l = tl l)
			modes += sprint(" %s %s", (hd l).t0, (hd l).t1);
		s := sprint("%s mode%s by %s", stamp(), modes, mm.f.nick);
		if(lowercase(mm.where) == ic.lnick)
			status.write("# "+s+"\n");
		else
			mwrite(mm.where, s);
	Quit =>
		if(ic.fromself(mm.f)) {
			mwriteall(sprint("%s you have quit from irc: %s", stamp(), mm.m));
			disconnect();
		} else {
			lnick := lowercase(mm.f.nick);
			said := 0;
			for(i := 0; i < len targets; i++) {
				t := targets[i];
				if(hasnick(t.joined, lnick) || t.lname == lnick) {
					t.joined = delnick(t.joined, lnick);
					writefile(t.users, sprint("-%s\n", mm.f.nick));
					mwrite(t.name, sprint("%s %s (%s) has quit: %s", stamp(), mm.f.nick, mm.f.text(), mm.m));
					said++;
				}
			}
			if(!said)
				mwrite(mm.f.nick, sprint("%s %s (%s) has quit: %s", stamp(), mm.f.nick, mm.f.text(), mm.m));
		}
	Error =>
		mwriteall(sprint("%s error: %s", stamp(), mm.m));
		disconnect();
	Squit =>
		mwriteall(sprint("%s squit: %s", stamp(), mm.m));
	Join =>
		t := gettarget(mm.where);
		t.joined = addnick(t.joined, mm.f.nick);
		writefile(t.users, sprint("+%s\n", mm.f.nick));
		mwrite(mm.where, sprint("%s %s (%s) has joined", stamp(), mm.f.nick, mm.f.text()));
	Part =>
		t := gettarget(mm.where);
		t.joined = delnick(t.joined, lowercase(mm.f.nick));
		writefile(t.users, sprint("-%s\n", mm.f.nick));
		if(ic.fromself(mm.f)) {
			mwrite(mm.where, sprint("%s you (%s) have left %s", stamp(), mm.f.text(), mm.where));
			t.shutdown();
		} else {
			mwrite(mm.where, sprint("%s %s (%s) has left", stamp(), mm.f.nick, mm.f.text()));
		}
	Kick =>
		t := gettarget(mm.where);
		lwho := lowercase(mm.who);
		t.joined = delnick(t.joined, lwho);
		writefile(t.users, sprint("-%s\n", mm.who));
		if(lwho == ic.lnick)
			mwrite(mm.where, sprint("%s you have been kicked by %s (%s)", stamp(), mm.f.nick, mm.m));
		else
			mwrite(mm.where, sprint("%s %s has been kicked by %s (%s)", stamp(), mm.who, mm.f.nick, mm.m));
	Topic =>
		mwrite(mm.where, sprint("%s topic is now: %s", stamp(), mm.m));
	Replytext or Errortext or Unknown =>
		msg := concat(mm.params);
		silent := 0;
		if(tagof mm == tagof Rimsg.Replytext)
			case int mm.cmd {
			irc->RPLwelcome =>
				if(state == Connecting)
					changestate(Connected);
				else
					warn("RPLwelcome while already connected");

			irc->RPLtopic =>	msg = "topic: "+msg;
			irc->RPLtopicset =>	msg = "topic set by: "+msg;
			irc->RPLinviting =>	msg = "inviting: "+msg;
			irc->RPLnames =>
				if(len mm.params == 3) {
					users := array[0] of string;
					t := gettarget(mm.where);
					(toks, nil) := tokens(mm.params[2], " ", -1);
					for(; toks != nil; toks = tl toks) {
						nick := name := hd toks;
						if(nick != nil && (nick[0] == '@' || nick[0] == '+'))
							nick = nick[1:];
						t.newjoined = addnick(t.newjoined, nick);
						users = addnick(users, name);
					}
					msg = "users: "+concat(users);
				}
			irc->RPLnamesdone =>
				t := gettarget(mm.where);
				diff := "";
				for(i := 0; i < len t.joined; i++)
					diff += sprint("-%s\n", t.joined[i]);
				for(i = 0; i < len t.newjoined; i++)
					diff += sprint("+%s\n", t.newjoined[i]);
				if(diff != nil)
					writefile(t.users, diff);
				t.joined = t.newjoined;
				t.newjoined = array[0] of string;
				msg = "end users";


			irc->RPLaway =>	
				t := findtargetname(mm.where);
				if(t == nil || t.dead) {
					t = status;
				} else {
					now := daytime->now();
					if(t.mtime+10*60 >= now && msg == t.prevaway)
						silent = 1;
					t.mtime = now;
					t.prevaway = msg;
					msg = "away: "+msg;
					
				}
				mwrite(t.name, sprint("%s %s", stamp(), msg));
				silent = 1;

			irc->RPLwhoisuser or irc->RPLwhoischannels or irc->RPLwhoisidle or irc->RPLendofwhois or irc->RPLwhoisserver or irc->RPLwhoisoperator =>
				t := findtargetname(mm.where);
				if(t == nil || t.dead)
					t = status;
				mwrite(t.name, sprint("%s %s", stamp(), msg));
				silent = 1;
			}
		if(!silent) {
			if(mm.where != nil)
				mwrite(mm.where, sprint("%s %s", stamp(), msg));
			else
				status.write(sprint("# %s %s\n", stamp(), msg));
		}
	* =>
		mwrite(netname, sprint("%s %s", stamp(), mm.text()));
	}

}

dostyx(gm: ref Tmsg)
{
	pick m := gm {
	Open =>
		(fid, mode, nil, err) := srv.canopen(m);
		if(fid == nil)
			return replyerror(m, err);
		q := int fid.path&16rff;
		t := findtarget(int fid.path>>8);
		if(t == nil || t.dead)
			return replyerror(m, Edead);
		case q {
		Qdata =>
			if(t == nil)
				return replyerror(m, Etarget);
			say(sprint("mode=%x oread=%x", mode, Sys->OREAD));
			if(mode == Sys->OREAD || mode == Sys->ORDWR) {
				case q {
				Qdata =>
					t.data = addfidfile(t.data, Fidfile.new(fid, t));
				}
				say("new data fidfile inserted");
			}

		Qevent =>
			ff := Fidfile.new(fid, nil);
			ff.putdata(connectstatus()+"\n");
			for(i := 0; i < len targets; i++)
				if(!targets[i].dead)
					ff.putdata(sprint("new %d %s\n", targets[i].id, targets[i].name));
			eventfile = addfidfile(eventfile, ff);
			say("new eventfile fidfile inserted");

		Qusers =>
			ff := Fidfile.new(fid, nil);
			for(i := 0; i < len t.joined; i++)
				ff.putdata(sprint("+%s\n", t.joined[i]));
			t.users = addfidfile(t.users, ff);
			say("new usersfile fidfile inserted");

		Qraw =>
			if(mode == Sys->OREAD || mode == Sys->ORDWR) {
				ff := Fidfile.new(fid, nil);
				rawfile = addfidfile(rawfile, ff);
				say("new rawfile fidfile inserted");
			}
		}
		t.opens++;
		srv.default(m);

	Write =>
		(f, err) := srv.canwrite(m);
		if(f == nil)
			return replyerror(m, err);
		t := findtarget(int f.path>>8);
		if(t == nil || t.dead)
			return replyerror(m, Edead);
		case int f.path&16rff {
		Qrootctl or Qctl =>
			ctl(m, t);
		Qraw =>
			l := stripnewline(string m.data);
			err = writeraw(l+"\r\n");
			if(err != nil)
				replyerror(m, err);
			else
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
		Qdata =>
			if(state != Connected)
				return replyerror(m, Enocon);
			if(t.id == 0)
				return replyerror(m, Estatus);
			(toks, nil) := tokens(string m.data, "\n", -1);
			for(; toks != nil; toks = tl toks) {
				say(sprint("writing to %q: %q", t.name, hd toks));
				err = writemsg(ref Timsg.Privmsg(t.name, hd toks));
				if(err != nil)
					return replyerror(m, "writing: "+err);
				dwrite(t.name, sprint("%s %8s: %s", stamp(), ic.nick, hd toks));
			}
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		* =>
			replyerror(m, "internal error");
		}

	Clunk or Remove =>
		f := srv.getfid(m.fid);
		if(f != nil && f.isopen) {
			t := findtarget(int f.path>>8);
			t.opens--;
			case q := int f.path&16rff {
			Qraw or Qevent or Qusers or Qdata =>
				case q {
				Qraw =>		rawfile = delfidfile(rawfile, f);
				Qevent =>	eventfile = delfidfile(eventfile, f);
				Qusers =>	t.users = delfidfile(t.users, f);
				Qdata =>	t.data = delfidfile(t.data, f);
				}
			}
			if(t.dead && t.opens == 0)
				targets = del(targets, t);
		}
		srv.default(m);

	Read =>
		f := srv.getfid(m.fid);
		if(f.qtype & Sys->QTDIR) {
			srv.default(m);
			return;
		}
		say(sprint("read f.path=%bd", f.path));
		q := int f.path&16rff;
		t := findtarget(int f.path>>8);
		if(t == nil)
			return replyerror(m, Etarget);
		if(t.dead) {
			srv.reply(ref Rmsg.Read(m.tag, array[0] of byte));
			return;
		}
		case q {
		Qraw =>
			fidread(rawfile, f, m, nil);
		Qevent =>
			fidread(eventfile, f, m, nil);
		Qnick =>
			if(ic == nil)
				replyerror(m, Enocon);
			else
				srv.reply(styxservers->readstr(m, ic.nick));
		Qname =>
			srv.reply(styxservers->readstr(m, t.name));
		Qusers =>
			fidread(t.users, f, m, nil);
		Qdata =>
			fidread(t.data, f, m, t);
		* =>
			srv.default(m);
		}

	Wstat =>
		f := srv.getfid(m.fid);
		if(f == nil || int f.path&16rff != Qdata) {
			srv.default(m);
			return;
		}
		t := findtarget(int f.path>>8);
		if(t == nil || t.dead)
			return replyerror(m, Edead);
		ff := findfidfile(t.data, f);
		n := int m.stat.length;
		have := 0;
		for(ff.histoff = t.end; ff.histoff >= t.begin && have+(newn := len t.hist[ff.histoff%len t.hist]) <= n; ff.histoff--)
			have += newn;
		srv.reply(ref Rmsg.Wstat(m.tag));

	Flush =>
		have := fidflush(eventfile, m.oldtag) || fidflush(rawfile, m.oldtag);
		for(i := 0; !have && i < len targets; i++)
			have = fidflush(targets[i].data, m.oldtag);
		srv.default(gm);

	* =>
		srv.default(gm);
	}
}

navigator(c: chan of ref Navop)
{
again:
	for(;;) {
		navop := <-c;
		say("have navop");
		t := findtarget(int navop.path>>8);
		pick op := navop {
		Stat =>
			say("navop stat");
			if(t == nil || t.dead)
				navop.reply <-= (nil, Edead);
			else
				navop.reply <-= (dir(int op.path, t.mtime), nil);

		Walk =>
			say("navop walk");
			case int op.path&16rff {
			Qroot =>
				if(op.name == "..") {
					op.reply <-= (dir(Qroot, starttime), nil);
					continue again;
				}
				for(i := Qrootctl; i <= Qnick; i++)
					if(files[i].t1 == op.name) {
						op.reply <-= (dir(files[i].t0, starttime), nil);
						continue again;
					}
				(wid, rem) := str->toint(op.name, 10);
				if(rem == nil && (newt := findtarget(wid)) != nil) {
					op.reply <-= (dir(Qdir|wid<<8, newt.mtime), nil);
					continue again;
				}
				op.reply <-= (nil, Enotfound);

			Qdir =>
				if(op.name == "..") {
					op.reply <-= (dir(Qroot, starttime), nil);
					continue again;
				}
				if(t == nil || t.dead) {
					op.reply <-= (nil, Edead);
					continue again;
				}
				for(i := Qctl; i <= Qdata; i++) {
					(nil, name, nil) := files[i];
					if(op.name == name) {
						op.reply <-= (dir(i|int op.path&~16rff, findtarget(int op.path>>8).mtime), nil);
						continue again;
					}
				}
				op.reply <-= (nil, Enotfound);

			* =>
				op.reply <-= (nil, Enotdir);
			}
		Readdir =>
			say("navop readdir");
			if(t == nil || t.dead) {
				op.reply <-= (nil, Edead);
				continue again;
			}
			if(int op.path == Qroot) {
				n := Qnick+1-Qrootctl;
				have := 0;
				for(i := 0; have < op.count && op.offset+i < len targets+n; i++)
					case Qrootctl+i {
					Qrootctl to Qnick =>
						op.reply <-= (dir(Qrootctl+i, starttime), nil);
						have++;
					* =>
						off := op.offset+i-n;
						if(!targets[off].dead) {
							op.reply <-= (dir(Qdir|(targets[off].id<<8), targets[off].mtime), nil);
							have++;
						}
					}
			} else {
				for(i := 0; i < op.count && op.offset+i <= Qdata-Qctl; i++)
					op.reply <-= (dir((int op.path&~16rff)|i+Qctl, t.mtime), nil);
			}
			op.reply <-= (nil, nil);
		}
	}
}

dir(path, mtime: int): ref Sys->Dir
{
	(nil, name, perm) := files[t := path&16rff];
	d := ref sys->zerodir;
	d.name = name;
	if(t == Qdir)
		d.name = string (path>>8);
	d.uid = d.gid = "ircfs";
	d.qid.path = big path;
	if(perm&Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mtime = d.atime = mtime;
	d.mode = perm;
	return d;
}

ctl(m: ref Tmsg.Write, t: ref Target)
{
	say(sprint("ctl on %q: %q", t.name, string m.data));

	line := string m.data;
	if(len line > 0 && line[len line-1] == '\n')
		line = line[:len line-1];
	(toks, rem) := tokens(line, " ", 1);
	if(toks == nil)
		return replyerror(m, "missing command");

	cmd := hd toks;
	if(!(state == Disconnected && (cmd == "connect" || cmd == "reconnect") || state == Connecting && cmd == "nick" || state == Connected))
		return replyerror(m, Enocon);

	err: string;
	case cmd {
	"connect" or "reconnect" =>
		if(state != Disconnected)
			return replyerror(m, "already connected or connecting");

		(cargs, nil) := tokens(rem, " ", -1);
		case cmd {
		"connect" =>
			if(len cargs != 2)
				return replyerror(m, "bad parameters, need two");
			(lastaddr, lastnick) = (hd cargs, hd tl cargs);

		"reconnect" =>
			if(len cargs != 0)
				return replyerror(m, "bad parameters, none allowed");

			if(lastaddr == nil || lastnick == nil)
				return replyerror(m, "not previously connected");
		}
		connect(lastaddr, lastnick);
	"join" =>
		if(rem == nil)
			return replyerror(m, "bad join");
		if(ischannel(rem))
			err = writemsg(ref Timsg.Join(rem));
		else
			gettarget(rem);
	"quit" =>
		msg := rem;
		if(msg == nil)
			msg = "ircfs!";
		err = writemsg(ref Timsg.Quit(msg));
	"back" =>
		err = writemsg(ref Timsg.Away(""));
	"away" =>
		err = writemsg(ref Timsg.Away(rem));
	"nick" =>
		if(state == Connecting) {
			lastnick = ic.nick = rem;
			ic.lnick = lowercase(ic.nick);
		}
		err = writemsg(ref Timsg.Nick(rem));
	"umode" =>
		err = writemsg(ref Timsg.Mode(ic.nick, (rem, nil)::nil));
	"whois" =>
		err = writemsg(ref Timsg.Whois(rem));
	"names" or "n" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		err = writemsg(ref Timsg.Names(t.name));
	"me" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		err = writemsg(ref Timsg.Privmsg(t.name, "\u0001ACTION "+rem+"\u0001"));
		if(err == nil)
			dwrite(t.name, sprint("%s *%s %s", stamp(), ic.nick, rem));
	"notice" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		err = writemsg(ref Timsg.Notice(t.name, rem));
		if(err == nil)
			mwrite(t.name, sprint("%s %8s: %s", stamp(), ic.nick, rem));

	"invite" =>
		(iargs, nil) := tokens(rem, " ", -1);
		if(len iargs != 2)
			return replyerror(m, "invite needs two parameteres");
		(inick, ichan) := (hd iargs, hd tl iargs);
		err = writemsg(ref Timsg.Invite(inick, ichan));

	"version" or "time" or "ping" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		if(rem != nil)
			return replyerror(m, "version/time/ping needs zero parameters");
		err = writemsg(ref Timsg.Privmsg(t.name, sprint("\u0001%s\u0001", str->toupper(cmd))));
		if(err == nil)
			mwrite(t.name, sprint("%s requested irc client %s", stamp(), cmd));

	"kick" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		(toks, rem) = tokens(rem, " ", 1);
		if(toks == nil)
			return replyerror(m, "missing nick");
		err = writemsg(ref Timsg.Kick(t.name, hd toks, rem));

	"op" or "deop" or "ban" or "unban" or "voice" or "devoice" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		way := "+";
		if(cmd[:2] == "de" || cmd[:2] == "un") {
			way = "-";
			cmd = cmd[2:];
		}
		mode := cmd[0:1];
		(toks, nil) = tokens(rem, " ", -1);
		while(toks != nil && err == nil) {
			modes: list of (string, string);
			for(i := 0; i < 3 && toks != nil; i++) {
				modes = (way+mode, hd toks)::modes;
				toks = tl toks;
			}
			err = writemsg(ref Timsg.Mode(t.name, modes));
		}
	"mode" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		(toks, rem) = tokens(rem, " ", 1);
		if(toks == nil)
			return replyerror(m, "missing mode");
		err = writemsg(ref Timsg.Mode(t.name, (hd toks, rem)::nil));

	"part" =>
		if(t.id == 0)
			return replyerror(m, "cannot part status window");
		if(t.ischan) {
			err = writemsg(ref Timsg.Part(t.name));
		} else {
			mwrite(t.name, sprint("you left"));
			t.shutdown();
		}

	"topic" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		if(line == "topic")
			err = writemsg(ref Timsg.Topicget(t.name));
		else
			err = writemsg(ref Timsg.Topicset(t.name, rem));

	* =>
		return replyerror(m, "bad command: "+cmd);
	}
	if(err != nil)
		return replyerror(m, err);
	srv.reply(ref Rmsg.Write(m.tag, len m.data));
}

replyerror(m: ref Tmsg, s: string)
{
	srv.reply(ref Rmsg.Error(m.tag, s));
}

changestate(i: int)
{
	state = i;
	writefile(eventfile, connectstatus()+"\n");
	say("new state: "+connectstatus());
}

disconnect()
{
	if(state == Disconnected)
		return;

	changestate(Disconnected);
	for(i := 1; i < len targets; i++)
		if(!targets[i].dead)
			targets[i].shutdown();
	kill(readerpid);
	kill(writerpid);
	readerpid = writerpid = -1;
}

connect(addr, newnick: string)
{
	changestate(Connecting);
	ircinch = chan of (ref Rimsg, string, string);
	ircoutch = chan[16] of array of byte;
	ircerrch = chan of string;

	spawn ircreader(pidc := chan of int, addr, newnick);
	readerpid = <-pidc;
	writerpid = <-pidc;
}

connectstatus(): string
{
	case state {
	Connected =>	return "connected "+ic.nick;
	Connecting =>	return "connecting";
	Disconnected =>	return "disconnected";
	* =>		return "unknown";
	}
}

concat(a: array of string): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += " "+a[i];
	if(s != nil)
		s = s[1:];
	return s;
}

tokens(s, splitstr: string, n: int): (list of string, string)
{
	if(s != nil && s[len s-1] == '\n')
		s = s[:len s-1];
	
	elem: string;
	toks: list of string;
	rem := s;
	while(n-- != 0 && rem != nil) {
		(elem, rem) = str->splitstrl(rem, splitstr);
		if(rem != nil)
			rem = rem[1:];
		toks = elem::toks;
	}
	if(n > 0)
		return (nil, s);
	return (reverse(toks), rem);
}

ircreader(pidc: chan of int, addr, newnick: string)
{
	pidc <-= sys->pctl(0, nil);
	say("dialing");
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0) {
		ircerrch <-= sprint("dial %s: %r", addr);
		return;
	}
	say("connected");

	err: string;
	(ic, err) = Ircc.new(conn.dfd, addr, newnick, newnick);
	if(err != nil) {
		ircerrch <-= err;
		return;
	}
	spawn ircwriter(pidc, conn.dfd);
	say("new ircc");

	for(;;) {
		(m, l, merr) := ic.readmsg();
		if(l == nil) {
			ircerrch <-= merr;
			break;
		}
		ircinch <-= (m, l, merr);
		if(merr != nil)
			say("have imsg: "+m.text());
	}
}

ircwriter(pidc: chan of int, fd: ref Sys->FD)
{
	pidc <-= sys->pctl(0, nil);
	say("ircwriter");
	for(;;) {
		d := <-ircoutch;
		if(d == nil)
			break;
		if(sys->write(fd, d, len d) != len d) {
			ircerrch <-= sprint("writing irc message: %r");
			break;
		}
	}
}

stamp(): string
{
	tm := daytime->local(daytime->now());
	return sprint("%02d:%02d", tm.hour, tm.min);
}

fidread(a: array of ref Fidfile, f: ref Fid, m: ref Tmsg.Read, t: ref Target)
{
	ff := findfidfile(a, f);
	if(ff == nil)
		return replyerror(m, "not opened for reading");
	ff.putread(m);
	while((rm := ff.styxop(t)) != nil)
		srv.reply(rm);
}

fidflush(a: array of ref Fidfile, tag: int): int
{
	for(i := 0; i < len a; i++)
		if(a[i].flushop(tag))
			return 1;
	return 0;
}

findfidfile(a: array of ref Fidfile, f: ref Fid): ref Fidfile
{
	for(i := 0; i < len a; i++)
		if(a[i].fid == f)
			return a[i];
	return nil;
}

addfidfile(a: array of ref Fidfile, ff: ref Fidfile): array of ref Fidfile
{
	return add(a, ff);
}

delfidfile(a: array of ref Fidfile, f: ref Fid): array of ref Fidfile
{
	for(i := 0; i < len a; i++)
		if(a[i].fid == f) {
			a[i] = a[len a-1];
			a = a[:len a-1];
			break;
		}
	return a;
}

grow[T](d: array of T, n: int): array of T
{
	r := array[len d+n] of T;
	r[:] = d;
	return r;
}

Fidfile.new(fid: ref Fid, t: ref Target): ref Fidfile
{
	histoff := 0;
	if(t != nil) {
		have := 0;
		for(histoff = t.end; histoff > t.begin && have+(newn := len t.hist[histoff%len t.hist]) <= Histdefault; histoff--)
			have += newn;
	}
	return ref Fidfile(fid, histoff, array[0] of ref Tmsg.Read, array[0] of array of byte);
}

Fidfile.write(f: self ref Fidfile, s: string)
{
	f.putdata(s);
	while((m := f.styxop(nil)) != nil)
		srv.reply(m);
}

Fidfile.putdata(f: self ref Fidfile, s: string)
{
	f.a = add(f.a, array of byte s);
}

Fidfile.putread(f: self ref Fidfile, m: ref Tmsg.Read)
{
	f.reads = add(f.reads, m);
}

Fidfile.styxop(ff: self ref Fidfile, t: ref Target): ref Rmsg.Read
{
	if(len ff.reads == 0)
		return nil;

	if(t == nil) {
		if(len ff.a == 0)
			return nil;
		(r, d) := (ff.reads[0], ff.a[0]);
		(ff.reads, ff.a) = (ff.reads[1:], ff.a[1:]);
		return ref Rmsg.Read(r.tag, d);
	}

	r := ff.reads[0];

	if(ff.histoff >= t.end)
		return nil;
	if(ff.histoff < t.begin)
		ff.histoff = t.begin;
	ff.reads = ff.reads[1:];

	d := array[0] of byte;
	while(ff.histoff < t.end && len d+len (nd := t.hist[ff.histoff%len t.hist]) <= r.count || len d == 0) {
		newd := array[len d+len nd] of byte;
		newd[:] = d;
		newd[len d:] = nd;
		d = newd;
		ff.histoff++;
	}
	return ref Rmsg.Read(r.tag, d);
}

Fidfile.flushop(f: self ref Fidfile, tag: int): int
{
	for(i := 0; i < len f.reads; i++)
		if(f.reads[i].tag == tag) {
			f.reads[i:] = f.reads[i+1:];
			f.reads = f.reads[:len f.reads-1];
			return 1;
		}
	return 0;
}

Target.new(name: string): ref Target
{
	logfd: ref Sys->FD;
	lname := lowercase(name);
	if(logpath != nil) {
		file := sprint("%s%s.log", logpath, lname);
		logfd = sys->open(file, Sys->OWRITE);
		if(logfd == nil)
			logfd = sys->create(file, Sys->OWRITE, 8r666);
		if(logfd != nil) {
			sys->seek(logfd, big 0, Sys->SEEKEND);
			say(sprint("opened logfile %s", file));
		} else
			warn(sprint("error operning logfile %s: %r", file));
	}
	return ref Target(
		lastid++, name, lname, ischannel(lname), logfd,
		array[0] of ref Fidfile, array[0] of ref Fidfile,
		array[0] of array of byte, 0,
		0, 0,
		array[0] of string, array[0] of string,
		0, 0, nil, daytime->now());
}

Target.putdata(t: self ref Target, s: string)
{
	d := array of byte s;
	t.mtime = daytime->now();
	while(t.histlen+len d > Histmax && t.begin < t.end) {
		t.histlen -= len t.hist[t.begin%len t.hist];
		t.begin++;
	}
	if(t.end-t.begin >= len t.hist)
		t.hist = grow(t.hist, 16);
	t.hist[(t.end++)%len t.hist] = d;
	t.histlen += len d;
}

Target.write(t: self ref Target, s: string)
{
	t.putdata(s);
	if(s != nil && t.logfd != nil) {
		if(sys->fprint(t.logfd, "%s", s) < 0)
			warn(sprint("writing log: %r"));
	}
	for(i := 0; i < len t.data; i++)
		while((m := t.data[i].styxop(t)) != nil)
			srv.reply(m);
}

Target.shutdown(t: self ref Target)
{
	if(!t.dead) {
		t.write("");
		for(i := 0; i < len t.users;i ++)
			t.users[i].write("");
		writefile(eventfile, sprint("del %d\n", t.id));
		t.dead = 1;
	}
}

writefile(a: array of ref Fidfile, s: string)
{
	for(i := 0; i < len a; i++)
		a[i].write(s);
}

findtarget(id: int): ref Target
{
	for(i := 0; i < len targets; i++)
		if(targets[i].id == id)
			return targets[i];
	return nil;
}

findtargetname(name: string): ref Target
{
	lname := lowercase(name);
	for(i := 0; i < len targets; i++)
		if(!targets[i].dead && targets[i].lname == lname)
			return targets[i];
	return nil;
}

gettarget(name: string): ref Target
{
	if(state == Connecting && status != nil)
		return status;
	t := findtargetname(name);
	if(t == nil) {
		t = Target.new(name);
		targets = add(targets, t);
		writefile(eventfile, sprint("new %d %s\n", t.id, name));
	}
	return t;
}

dwrite(name, text: string)
{
	gettarget(name).write("+ "+text+"\n");
}

mwrite(name, text: string)
{
	gettarget(name).write("# "+text+"\n");
}

mwriteall(text: string)
{
	text = "# "+text+"\n";
	for(i := 0; i < len targets; i++)
		targets[i].write(text);
}

writeraw(s: string): string
{
	d := array of byte s;
	if(len d > Irc->Maximsglen)
		return "line too long";
	alt {
	ircoutch <-= d =>
		writefile(rawfile, "<<< "+s);
		return nil;
	* =>
		return "output buffer full, dropping line";
	}
}

writemsg(m: ref Timsg): string
{
	say("writing message: "+m.text());
	packed := m.pack();
	return writeraw(packed);
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

hasnick(a: array of string, le: string): int
{
	return indexnick(a, le) >= 0;
}

indexnick(a: array of string, le: string): int
{
	for(i := 0; i < len a; i++)
		if(lowercase(a[i]) == le)
			return i;
	return -1;
}

addnick(a: array of string, e: string): array of string
{
	if(!hasnick(a, lowercase(e)))
		a = add(a, e);
	return a;
}

delnick(a: array of string, le: string): array of string
{
	if((i := indexnick(a, le)) >= 0) {
		a[i:] = a[i+1:];
		a = a[:len a-1];
	}
	return a;
}

stripnewline(l: string): string
{
	if(len l >= 2 && l[len l-2:] == "\r\n")
		l = l[:len l-2];
	if(len l >= 1 && l[len l-1:] == "\n")
		l = l[:len l-1];
	return l;
}

kill(pid: int)
{
	fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

say(s: string)
{
	if(dflag)
		sys->fprint(sys->fildes(2), "%s\n", s);
}
