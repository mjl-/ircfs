# ircfs design.
#
# each channel and user is represented by a Target.
# there is also a (one) status Target, for all messages not for a (specific) channel or user.
#
# an open file is represented by a Fidfile.  e.g. a Target's "data"
# or "users" is represented as an array of Fidfile's.
# a Fidfile is an array of buffers and an array of styx reads.
# for Qdata files, the hist buffers of the Target are used instead of the Fidfile buffers.
# adding data to a Fidfile just appends to the buffers array.  a styx read is appended to the reads array.
# after a data write/styx read, as many styx reads as possible are returned for the data available.
#
# threads:
# - main, styx & irc messages and other events go here.  main owns almost all data structures.
# - navigator, styx navigator.  (runs in lockstep with main, so can access data structures directly).
# - ircreader, dials the irc server, spawns ircwriter, reads irc messages (sending them to main)
# - ircwriter, writes irc messages to network
# - dayticker, sleeps the whole day, wakes up at midnight to print a "day changed" message
# - pingwatch, spawned after sending a ping.  sleeps, then signals main for pong timeout.  it's normally killed when pong arrives in time.
# - nextping, spawned after receiving pong.  wakes up & signals main when it's time to send another ping.
#
# the lower 8 bits of qids are the type of file.  the 24 higher bits are Target.id.
#
# other notes:
# - variable names start with l are usually lowercased names (according to irc rules)

implement Ircfs;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "dial.m";
	dial: Dial;
include "string.m";
	str: String;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
include "daytime.m";
	dt: Daytime;
include "irc.m";
	irc: Irc;
	lowercase, ischannel, Irccon, Timsg, Rimsg, From: import irc;

Etarget: 	con "no such target";
Eeof:		con "target closed";
Enocon:		con "not connected";
Estatus:	con "invalid on status file";
Enotchan:	con "only works on channel";
Ebadctl:	con "bad ctl message";
Enotfound, Enotdir: import Styxservers;

Histmax:	con 32*1024;
Histdefault:	con 32*1024;

Disconnected, Dialing, Connecting, Connected: con iota;

dflag, tflag: int;
logpath: string;
netname: string;	# used for the name of the status Target
lastnick,
lastpass,
lastaddr,
lastfromhost: string;	# connection parameters
state := Disconnected;
connectmsg: ref Tmsg.Write;	# only non-nil when connecting:  the ctl write "connect"
starttime: int;
imsgselflen := 0;	# length of our full irc path (nick,user,host)

Qroot, Qrootctl, Qevent, Qraw, Qnick, Qpong, Qdir, Qctl, Qname, Qusers, Qdata: con iota;
files := array[] of {
	(Qroot,		".",	Sys->DMDIR|8r555),

	(Qrootctl,	"ctl",	8r222),
	(Qevent,	"event",8r444),
	(Qraw,		"raw",	8r666),
	(Qnick,		"nick",	8r444),
	(Qpong,		"pong",	8r444),

	(Qdir, 		"",	Sys->DMDIR|8r555),
	(Qctl,		"ctl",	8r222),
	(Qname,		"name",	8r444),
	(Qusers,	"users",8r444),
	(Qdata,		"data",	8r666),
};

lastid := 0;
Target: adt {
	id:	int;
	name,
	lname:	string;  # cased and lower-cased name
	ischan:	int;
	logfd:	ref Sys->FD;
	data,
	users:	array of ref Fidfile;
	hist:	array of array of byte;
	histlength,		# total length of hist in bytes
	histfirst,		# index of histbegin in hist
	histbegin,		# first logical entry in hist, increases 1 for each buf added
	histend:	int;	# last+1 logical entry in hist.
	joined,		# cased users currently joined, and 
	newjoined:	array of string;	# new list of joined users currently constructed
	eof:	int;	# whether no more new data will arrive
	opens:	int;	# ref count, if eof && remove && opens==0, we remove a target
	remove:	int;	# whether to remove target on eof
	prevaway:	string;
	mtime:	int;

	new:	fn(name: string): ref Target;
	write:	fn(f: self ref Target, s: string);
	putdata:	fn(f: self ref Target, s: string);
	shutdown:	fn(f: self ref Target);
};

Fidfile: adt {
	fid:	ref Fid;
	histoff:	int;	# logical line offset into Target.hist, like Target.histbegin
	histo:		int;	# byte offset into histoff
	reads:	array of ref Tmsg.Read;

	a:	array of array of byte;
	singlebuf:	int;  # whether to only store one buffer to read

	new:		fn(fid: ref Fid, t: ref Target, singlebuf: int): ref Fidfile;
	write:		fn(f: self ref Fidfile, s: string);
	putdata:	fn(f: self ref Fidfile, s: string);
	putread:	fn(f: self ref Fidfile, m: ref Tmsg.Read);
	sethist:	fn(f: self ref Fidfile, t: ref Target, n: int);
	styxop:		fn(f: self ref Fidfile, t: ref Target): ref Rmsg;  # Rmsg.Read or Rmsg.Error
	flushop:	fn(f: self ref Fidfile, tag: int): int;
};
rawfile := array[0] of ref Fidfile;
eventfile := array[0] of ref Fidfile;
pongfile := array[0] of ref Fidfile;

ic: ref Irccon;
srv: ref Styxserver;
targets := array[0] of ref Target;
status: ref Target;
ircinc: chan of (ref Rimsg, string, string);
ircoutc: chan of array of byte;
ircerrc: chan of string;
dayc: chan of int;
dialerrc: chan of string;
dialc: chan of (int, int);

# we ping the server Pinginterval seconds after receiving the previous pong (and after connection setup, to get it going).
# if pong is within 5 secs, we write "pong X" with X the delay
# if pong is later, keep writing "nopong X" every 5 seconds until the pong arrives, X is the total delay since the ping.
nextpingc: chan of int;
pingwatchc: chan of int;
pingtime: int;		# time of last ping to server
Pinginterval: con 60;	# seconds between ircfs pong and next ping
Noponginterval: con 5;	# seconds ircfs waits before sending nopong

readerpid := writerpid := nextpingpid := pingwatchpid := -1;

Ircfs: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	dial = load Dial Dial->PATH;
	str = load String String->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	styxservers->init(styx);
	dt = load Daytime Daytime->PATH;
	irc = load Irc Irc->PATH;
	irc->init();

	arg->init(args);
	arg->setusage(arg->progname()+" [-dt] [-a addr] [-f fromhost] [-n nick] [-p password] [-l logpath] netname");
	while((c := arg->opt()) != 0)
		case c {
		'a' =>	lastaddr = arg->earg();
		'n' =>	lastnick = arg->earg();
		'p' =>	lastpass = arg->earg();
		'f' =>	lastfromhost = arg->earg();
		'l' =>	logpath = arg->earg();
			if(logpath != nil && logpath[len logpath-1] != '/')
				logpath += "/";
		't' =>	tflag++;
		'd' =>	dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	netname = hd args;

	sys->pctl(Sys->NEWPGRP, nil);

	status = gettarget(sprint("(%s)", netname));
	starttime = dt->now();

	ircinc = chan of (ref Rimsg, string, string);
	ircoutc = chan[16] of array of byte;
	ircerrc = chan of string;
	dayc = chan of int;
	dialerrc = chan of string;
	dialc = chan of (int, int);
	nextpingc = chan of int;
	pingwatchc = chan of int;

	spawn dayticker();

	navch := chan of ref Navop;
	spawn navigator(navch);

	nav := Navigator.new(navch);
	msgc: chan of ref Tmsg;
	(msgc, srv) = Styxserver.new(sys->fildes(0), nav, big Qroot);

	spawn main(msgc);
}

weekdays := array[] of {"sun", "mon", "tues", "wednes", "thurs", "fri", "satur"};
main(msgc: chan of ref Tmsg)
{
Done:
	for(;;) alt {
	<-dayc =>
		tm := dt->local(dt->now());
		daystr := sprint("! day changed, %d-%02d-%02d, %sday\n", tm.year+1900, tm.mon+1, tm.mday, weekdays[tm.wday]);
		for(i := 0; i < len targets; i++)
			if(!targets[i].eof)
				targets[i].write(daystr);

	<-pingwatchc =>
		writefile(pongfile, sprint("nopong %d\n", dt->now()-pingtime));

	<-nextpingc =>
		ping();

	(m, line, err) := <-ircinc =>
		say(sprint("ircin, err %q, line %q", err, line));
		if(line != nil)
			writefile(rawfile, ">>> "+line);

		if(err != nil) {
			status.write(sprint("# bad irc message: %s (%s)\n", stripnewline(line), err));
			continue;
		}

		doirc(m);

	err := <-dialerrc =>
		say(sprint("dialerrc, err %q", err));
		status.write("# dial failed: "+err);
		if(connectmsg != nil)
			replyerror(connectmsg, err);
		connectmsg = nil;
		disconnect();

	(rpid, wpid) := <-dialc =>
		say(sprint("dialc, pids %d %d", rpid, wpid));
		status.write("# remote dialed, connecting...\n");
		changestate(Connecting);
		readerpid = rpid;
		writerpid = wpid;
		# note: state is set to Connected when irc welcome message is read.

	err := <-ircerrc =>
		say(sprint("ircerrc, err %q", err));
		status.write("# irc connection error: "+err+"\n");
		disconnect();

	mm := <-msgc =>
		if(mm == nil)
			break Done;
		pick m := mm {
		Readerror =>
			warn("read error: "+m.error);
			break Done;
		}
		dostyx(mm);
	}
	killgrp(pid());
}

dayticker()
{
	for(;;) {
		tm := dt->local(dt->now());
		secs := 24*3600-3*60 - (tm.hour*3600+tm.min*60+tm.sec);
		if(secs > 0)
			sys->sleep(1000*secs);
		tm = dt->local(dt->now());
		secs = 24*3600 - (tm.hour*3600+tm.min*60+tm.sec);
		sys->sleep(secs*1000+200);
		dayc <-= 1;
		sys->sleep(3600*1000);
	}
}

nextping(pidc: chan of int)
{
	pidc <-= pid();
	sys->sleep(Pinginterval*1000);
	nextpingc <-= 1;
}

pingwatch(pidc: chan of int)
{
	pidc <-= pid();
	for(;;) {
		sys->sleep(Noponginterval*1000);
		pingwatchc <-= 1;
	}
}

ping()
{
	err := writemsg(ref Timsg.Ping (ic.server));
	if(err != nil)
		warn("writing ping request: "+err);
	spawn pingwatch(pidc := chan of int);
	pingwatchpid = <-pidc;
	pingtime = dt->now();
}

doirc(mm: ref Rimsg)
{
	pick m := mm {
	Ping =>
		err := writemsg(ref Timsg.Pong(m.who, m.m));
		if(err != nil)
			warn("writing pong: "+err);

	Pong =>
		kill(pingwatchpid);
		pingwatchpid = -1;
		writefile(pongfile, sprint("pong %d\n", dt->now()-pingtime));
		spawn nextping(pidc := chan of int);
		nextpingpid = <-pidc;

	Notice =>
		if(ischannel(m.where))
			t := findtargetname(m.where);
		if(t == nil && lowercase(m.where) == ic.lnick && m.f != nil)
			t = findtargetname(m.f.nick);
		if(t == nil)
			t = status;

		from := "";
		if(m.f != nil)
			from = m.f.nick;
		t.write(sprint("# %s %8s: %s\n", stamp(), from, m.m));

	Privmsg =>
		server := nick := "";
		if(m.f != nil) {
			nick = m.f.nick;
			server = m.f.server;
		}
		s := m.m;
		action: con "\u0001ACTION ";
		if(len s > len action && s[:len action] == action && s[len s-1] == 16r01)
			s = sprint("%s *%s %s", stamp(), nick, s[len action:len s-1]);
		else
			s = sprint("%s %8s: %s", stamp(), nick, s);
		targ := m.where;
		if(lowercase(m.where) == ic.lnick)
			targ = nick;
		dwrite(targ, s);

	Nick =>
		if(ic.fromself(m.f)) {
			lastnick = ic.nick = m.name;
			ic.lnick = lowercase(ic.nick);
			mwriteall(sprint("%s you are now known as %s", stamp(), ic.nick));
			writefile(eventfile, sprint("nick %s\n", ic.nick));

			# to find our user & hostname, for imsgselflen
			err := writemsg(ref Timsg.Whois(ic.nick));
			if(err != nil)
				warn("writing whois request: "+err);
			return;
		}

		lnick := lowercase(m.f.nick);
		said := 0;
		for(i := 0; i < len targets; i++) {
			t := targets[i];
			if(t.eof)
				continue;
			if(hasnick(t.joined, lnick) || t.lname == lnick) {
				t.newjoined = delnick(t.newjoined, lnick);
				t.newjoined = addnick(t.newjoined, m.name);
				t.joined = delnick(t.joined, lnick);
				t.joined = addnick(t.joined, m.name);
				writefile(t.users, sprint("+%s\n-%s\n", m.name, m.f.nick));
				mwrite(t.name, sprint("%s %s is now known as %s", stamp(), m.f.nick, m.name));
				said++;
			}
			if(t.lname == lnick) {
				t.name = m.name;
				t.lname = lowercase(t.name);
			}
		}
		if(said == 0)
			mwrite(m.name, sprint("%s %s is now known as %s", stamp(), m.f.nick, m.name));
	Mode =>
		modes := "";
		for(l := m.modes; l != nil; l = tl l) {
			(mode, args) := (hd l);
			modes += " "+mode;
			for(; args != nil; args = tl args)
				modes += " "+hd args;
		}
		s := sprint("%s mode%s by %s", stamp(), modes, m.f.nick);
		if(lowercase(m.where) == ic.lnick)
			status.write("# "+s+"\n");
		else
			mwrite(m.where, s);
	Quit =>
		if(ic.fromself(m.f)) {
			mwriteall(sprint("%s you have quit from irc: %s", stamp(), m.m));
			disconnect();
			return;
		}

		lnick := lowercase(m.f.nick);
		said := 0;
		for(i := 0; i < len targets; i++) {
			t := targets[i];
			if(t.eof)
				continue;
			t.newjoined = delnick(t.newjoined, lnick);
			if(hasnick(t.joined, lnick) || t.lname == lnick) {
				t.joined = delnick(t.joined, lnick);
				writefile(t.users, sprint("-%s\n", m.f.nick));
				mwrite(t.name, sprint("%s %s (%s) has quit: %s", stamp(), m.f.nick, m.f.text(), m.m));
				said++;
			}
		}
		if(said == 0)
			mwrite(m.f.nick, sprint("%s %s (%s) has quit: %s", stamp(), m.f.nick, m.f.text(), m.m));
	Error =>
		mwriteall(sprint("%s error: %s", stamp(), m.m));
		disconnect();
	Squit =>
		mwriteall(sprint("%s squit: %s", stamp(), m.m));
	Join =>
		t := gettarget(m.where);
		t.joined = addnick(t.joined, m.f.nick);
		t.newjoined = addnick(t.newjoined, m.f.nick);
		writefile(t.users, sprint("+%s\n", m.f.nick));
		mwrite(m.where, sprint("%s %s (%s) has joined", stamp(), m.f.nick, m.f.text()));
	Part =>
		t := gettarget(m.where);
		lnick := lowercase(m.f.nick);
		t.joined = delnick(t.joined, lnick);
		t.newjoined = delnick(t.newjoined, lnick);
		writefile(t.users, sprint("-%s\n", m.f.nick));
		if(ic.fromself(m.f)) {
			mwrite(m.where, sprint("%s you (%s) have left %s", stamp(), m.f.text(), m.where));
			shutdown(t);
		} else {
			mwrite(m.where, sprint("%s %s (%s) has left", stamp(), m.f.nick, m.f.text()));
		}
	Kick =>
		t := gettarget(m.where);
		lwho := lowercase(m.who);
		t.newjoined = delnick(t.newjoined, lwho);
		t.joined = delnick(t.joined, lwho);
		writefile(t.users, sprint("-%s\n", m.who));
		if(lwho == ic.lnick)
			mwrite(m.where, sprint("%s you have been kicked by %s (%s)", stamp(), m.f.nick, m.m));
		else
			mwrite(m.where, sprint("%s %s has been kicked by %s (%s)", stamp(), m.who, m.f.nick, m.m));
	Topic =>
		mwrite(m.where, sprint("%s new topic by %s: %s", stamp(), m.f.nick, m.m));
	Invite =>
		mwrite(m.where, sprint("%s %s invites %s to join %s", stamp(), m.f.nick, m.who, m.where));
	Replytext or
	Errortext or
	Unknown =>
		msg := concat(m.params);
		silent := 0;
		if(tagof m == tagof Rimsg.Replytext)
			case int m.cmd {
			irc->RPLwelcome =>
				if(state == Connecting) {
					status.write("# connected");
					if(connectmsg != nil)
						srv.reply(ref Rmsg.Write (connectmsg.tag, len connectmsg.data));
					connectmsg = nil;
					changestate(Connected);

					# to find our user & hostname, for imsgselflen
					err := writemsg(ref Timsg.Whois(ic.nick));
					if(err != nil)
						warn("writing whois request: "+err);

					# first ping, to get the pong/nopong process going
					ic.server = m.f.server;
					ping();
				} else
					warn("RPLwelcome while already connected");

			irc->RPLtopic =>	msg = "topic: "+msg;
			irc->RPLtopicset =>	msg = "topic set by: "+msg;
			irc->RPLinviting =>	msg = "inviting: "+msg;
			irc->RPLnames =>
				if(len m.params == 3) {
					users := array[0] of string;
					t := gettarget(m.where);
					(toks, nil) := tokens(m.params[2], " ", -1);
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
				t := gettarget(m.where);
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
				t := findtargetname(m.where);
				if(t == nil || t.eof)
					t = status;
				now := dt->now();
				if(t.mtime+10*60 >= now && msg == t.prevaway)
					silent = 1;
				t.mtime = now;
				t.prevaway = msg;
				msg = "away: "+msg;
				if(!silent)
					mwrite(t.name, sprint("%s %s", stamp(), msg));
				silent = 1;

			irc->RPLwhoisuser or
			irc->RPLwhoischannels or
			irc->RPLwhoisidle or
			irc->RPLendofwhois or
			irc->RPLwhoisserver or
			irc->RPLwhoisoperator =>
				t := findtargetname(m.where);
				if(t == nil || t.eof)
					t = status;
				mwrite(t.name, sprint("%s %s", stamp(), msg));
				silent = 1;

				# whois response on ourself.  gives approx how many of 512 bytes of irc message is taken by our 'from'.
				if(int m.cmd == irc->RPLwhoisuser && m.where == ic.lnick && len m.params >= 2) {
					user := m.params[0];
					host := m.params[1];
					# ":nick!user@host "
					imsgselflen = 1+len ic.lnick+1+len user+1+len host+1;
				}

			irc->RPLchannelmode =>
				msg = "mode "+msg;
			irc->RPLchannelmodechanged =>
				msg = "mode changed "+msg;
			}
		else if(tagof m == tagof Rimsg.Errortext)
			case int m.cmd {
			irc->RPLnosuchnick or
			irc->RPLnosuchchannel or
			irc->RPLcannotsendtochan or
			irc->RPLtoomanychannels or
			irc->RPLwasnosuchnick =>
				t := findtargetname(m.where);
				if(t == nil || t.eof)
					t = status;
				t.write(sprint("# %s %s\n", stamp(), msg));
				silent = 1;
			}
		if(!silent) {
			if(m.where != nil)
				mwrite(m.where, sprint("%s %s", stamp(), msg));
			else
				status.write(sprint("# %s %s\n", stamp(), msg));
		}
	* =>
		mwrite(netname, sprint("%s %s", stamp(), m.text()));
	}
}

dostyx(mm: ref Tmsg)
{
	pick m := mm {
	Open =>
		(fid, mode, nil, err) := srv.canopen(m);
		if(fid == nil)
			return replyerror(m, err);
		q := int fid.path&16rff;

		t := findtarget(int fid.path>>8);
		if(t == nil)
			return replyerror(m, Eeof);

		case q {
		Qusers =>
			ff := Fidfile.new(fid, nil, 0);
			for(i := 0; i < len t.joined; i++)
				ff.putdata(sprint("+%s\n", t.joined[i]));
			t.users = addfidfile(t.users, ff);
			say("new usersfile fidfile inserted");

		Qdata =>
			if((mode == Sys->OREAD || mode == Sys->ORDWR) && q == Qdata) {
				t.data = addfidfile(t.data, Fidfile.new(fid, t, 0));
				say("new data fidfile inserted");
			}

		Qevent =>
			ff := Fidfile.new(fid, nil, 0);
			ff.putdata(connectstatus()+"\n");
			for(i := 0; i < len targets; i++)
				if(!targets[i].remove)
					ff.putdata(sprint("new %d %s\n", targets[i].id, targets[i].name));
			eventfile = addfidfile(eventfile, ff);
			say("new eventfile fidfile inserted");

		Qpong =>
			ff := Fidfile.new(fid, nil, 1);
			pongfile = addfidfile(pongfile, ff);
			say("new pongfile fidfile inserted");

		Qraw =>
			if(mode == Sys->OREAD || mode == Sys->ORDWR) {
				ff := Fidfile.new(fid, nil, 0);
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
		q := int f.path&16rff;
		t := findtarget(int f.path>>8);
		if(t == nil)
			return replyerror(m, Eeof);
		case q {
		Qrootctl or
		Qctl =>
			ctl(m, t);
		Qraw =>
			if(state != Connected)
				return replyerror(m, Enocon);
			l := stripnewline(string m.data);
			err = writeraw(l+"\r\n");
			if(err != nil)
				replyerror(m, err);
			else
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
		Qdata =>
			if(state != Connected)
				return replyerror(m, Enocon);
			if(t.eof)
				return replyerror(m, Eeof);
			if(t.id == 0)
				return replyerror(m, Estatus);
			(toks, nil) := tokens(string m.data, "\n", -1);
			for(; toks != nil; toks = tl toks) {
				say(sprint("writing to %q: %q", t.name, hd toks));
				err = writemsg(ref Timsg.Privmsg(t.name, hd toks));
				if(err != nil)
					return replyerror(m, err);
				sdwrite(t.name, sprint("%s %8s: %s", stamp(), ic.nick, hd toks));
			}
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		* =>
			replyerror(m, "internal error");
		}

	Clunk or
	Remove =>
		f := srv.getfid(m.fid);
		if(f != nil && f.isopen) {
			t := findtarget(int f.path>>8);
			q := int f.path&16rff;
			t.opens--;
			case q {
			Qraw =>		rawfile = delfidfile(rawfile, f);
			Qevent =>	eventfile = delfidfile(eventfile, f);
			Qpong =>	pongfile = delfidfile(pongfile, f);
			Qusers =>	t.users = delfidfile(t.users, f);
			Qdata =>	t.data = delfidfile(t.data, f);
			}
			if(t.eof && t.remove && t.opens == 0)
				targets = del(targets, t);
		}
		srv.default(m);

	Read =>
		f := srv.getfid(m.fid);
		if(f.qtype & Sys->QTDIR) {
			srv.default(m);
			return;
		}
		q := int f.path&16rff;
		t := findtarget(int f.path>>8);
		if(t == nil)
			return replyerror(m, Etarget);
		case q {
		Qraw =>		fidread(rawfile, f, m, nil);
		Qevent =>	fidread(eventfile, f, m, nil);
		Qpong =>	fidread(pongfile, f, m, nil);
		Qusers =>	fidread(t.users, f, m, nil);
		Qdata =>	fidread(t.data, f, m, t);
		Qnick =>
			n := lastnick;
			if(ic != nil)
				n = ic.nick;
			srv.reply(styxservers->readstr(m, n));
		Qname =>	srv.reply(styxservers->readstr(m, t.name));
		* =>		srv.default(m);
		}

	Wstat =>
		f := srv.getfid(m.fid);
		if(f == nil || int f.path&16rff != Qdata) {
			srv.default(m);
			return;
		}
		t := findtarget(int f.path>>8);
		if(t == nil || t.eof)
			return replyerror(m, Eeof);
		if(state != Connected)
			return replyerror(m, Enocon);
		# wstat for length should only happen when file has been opened.  but for linux/9pfuse users accept & ignore them on non-opened files.
		ff := findfidfile(t.data, f);
		if(ff != nil)
			ff.sethist(t, int m.stat.length);
		srv.reply(ref Rmsg.Wstat(m.tag));

	Flush =>
		if(connectmsg != nil && connectmsg.tag == m.oldtag)
			connectmsg = nil;

		have := fidflush(eventfile, m.oldtag) || fidflush(rawfile, m.oldtag) || fidflush(pongfile, m.oldtag);
		for(i := 0; !have && i < len targets; i++)
			have = fidflush(targets[i].data, m.oldtag);
		srv.default(mm);

	* =>
		srv.default(mm);
	}
}

navigator(c: chan of ref Navop)
{
	for(;;)
		navigate(<-c);
}

navigate(navop: ref Navop)
{
	id := int navop.path>>8;
	q := int navop.path&16rff;
	t := findtarget(id);
	pick op := navop {
	Stat =>
		if(t == nil)
			navop.reply <-= (nil, Eeof);
		else
			navop.reply <-= (dir(int op.path, t.mtime), nil);

	Walk =>
		if(op.name == "..") {
			destq := Qroot;
			mtime := starttime;
			if(q >= Qctl && q <= Qdata) {
				destq = Qdir|(id<<8);
				mtime = t.mtime;
			}
			op.reply <-= (dir(destq, mtime), nil);
			return;
		}

		case q {
		Qroot =>
			for(i := Qrootctl; i <= Qpong; i++)
				if(files[i].t1 == op.name) {
					op.reply <-= (dir(files[i].t0, starttime), nil);
					return;
				}
			(wid, rem) := str->toint(op.name, 10);
			if(rem == nil && (newt := findtarget(wid)) != nil) {
				op.reply <-= (dir(Qdir|wid<<8, newt.mtime), nil);
				return;
			}
			op.reply <-= (nil, Enotfound);

		Qdir =>
			if(t == nil) {
				op.reply <-= (nil, Eeof);
				return;
			}
			for(i := Qctl; i <= Qdata; i++) {
				(nil, name, nil) := files[i];
				if(op.name == name) {
					op.reply <-= (dir(i|(id<<8), t.mtime), nil);
					return;
				}
			}
			op.reply <-= (nil, Enotfound);

		* =>
			op.reply <-= (nil, Enotdir);
		}
	Readdir =>
		if(t == nil) {
			op.reply <-= (nil, Eeof);
			return;
		}
		if(int op.path == Qroot) {
			nfixed: con Qpong+1-Qrootctl;
			have := 0;
			for(i := op.offset; have < op.count && i < nfixed+len targets; i++)
				case i {
				0 to nfixed-1 =>
					op.reply <-= (dir(Qrootctl+i, starttime), nil);
					have++;
				* =>
					off := i-nfixed;
					op.reply <-= (dir(Qdir|(targets[off].id<<8), targets[off].mtime), nil);
					have++;
				}
		} else {
			for(i := 0; i < op.count && op.offset+i <= Qdata-Qctl; i++)
				op.reply <-= (dir((int op.path&~16rff)|i+Qctl, t.mtime), nil);
		}
		op.reply <-= (nil, nil);
	}
}

dir(path, mtime: int): ref Sys->Dir
{
	(nil, name, perm) := files[t := path&16rff];
	d := ref sys->zerodir;
	d.name = name;
	if(t == Qdir)
		d.name = string (path>>8);
	d.uid = d.gid = "irc";
	d.qid.path = big path;
	if(perm&Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mtime = d.atime = mtime;
	d.mode = perm;
	return d;
}

noeofctls := array[] of {
"names", "n", "me", "notice", "version", "time", "ping", "ctcp",
"kick", "op", "deop", "ban", "unban", "voice", "devoice", "mode", "part", "topic",
};
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
	if((state == Disconnected && cmd != "connect" && cmd != "reconnect"
	|| state == Connecting && cmd != "nick"
	|| state == Dialing) && cmd != "debug")
		return replyerror(m, Enocon);

	if(t.eof) {
		for(i := 0; i < len noeofctls; i++)
			if(noeofctls[i] == cmd)
				return replyerror(m, Eeof);
	}

	err: string;
	case cmd {
	"debug" =>
		dflag = int rem;

	"connect" or
	"reconnect" =>
		if(state != Disconnected)
			return replyerror(m, "already connected or connecting");

		(cargs, nil) := tokens(rem, " ", -1);
		case cmd {
		"connect" =>
			if(len cargs != 2 && len cargs != 3 && len cargs != 4)
				return replyerror(m, "bad parameters, need address, nick and optionally password and fromhost");
			(lastaddr, lastnick) = (hd cargs, hd tl cargs);
			lastfromhost = nil;
			lastpass = nil;
			if(len cargs >= 3)
				lastpass = hd tl tl cargs;
			if(len cargs >= 4)
				lastfromhost = hd tl tl tl cargs;

		"reconnect" =>
			if(len cargs != 0)
				return replyerror(m, "bad parameters, none allowed");

			if(lastaddr == nil || lastnick == nil)
				return replyerror(m, "not previously connected");
		}

		changestate(Dialing);
		ircinc = chan of (ref Rimsg, string, string);
		ircoutc = chan[16] of array of byte;
		ircerrc = chan of string;

		connectmsg = m;
		spawn ircreader(lastaddr, lastfromhost, lastnick, lastpass);
		return;

	"join" =>
		if(rem == nil)
			return replyerror(m, "bad join");
		(name, key) := str->splitstrl(rem, " ");
		if(ischannel(name))
			err = writemsg(ref Timsg.Join(name, key));
		else if(key != nil)
			return replyerror(m, "bogus key for non-channel");
		else
			gettarget(name);
	"disconnect" or
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
		err = writemsg(ref Timsg.Mode(ic.nick, rem::nil));
	"whois" =>
		err = writemsg(ref Timsg.Whois(rem));
	"names" or
	"n" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		err = writemsg(ref Timsg.Names(t.name));
	"me" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		err = writemsg(ref Timsg.Privmsg(t.name, "\u0001ACTION "+rem+"\u0001"));
		if(err == nil)
			sdwrite(t.name, sprint("%s *%s %s", stamp(), ic.nick, rem));
	"notice" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		err = writemsg(ref Timsg.Notice(t.name, rem));
		if(err == nil)
			mwrite(t.name, sprint("%s %8s: %s", stamp(), ic.nick, rem));

	"msg" =>
		(name, s) := tokens(rem, " ", 1);
		if(name == nil || s == nil)
			return replyerror(m, Ebadctl);
		err = writemsg(ref Timsg.Privmsg(hd name, s));
		if(err == nil)
			sdwrite(hd name, sprint("%s %8s: %s", stamp(), ic.nick, s));

	"invite" =>
		(iargs, nil) := tokens(rem, " ", -1);
		if(len iargs != 2)
			return replyerror(m, "invite needs two parameteres");
		(inick, ichan) := (hd iargs, hd tl iargs);
		err = writemsg(ref Timsg.Invite(inick, ichan));

	"version" or
	"time" or
	"ping" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		if(rem != nil)
			return replyerror(m, "version/time/ping needs zero parameters");
		err = writemsg(ref Timsg.Privmsg(t.name, sprint("\u0001%s\u0001", str->toupper(cmd))));
		if(err == nil)
			mwrite(t.name, sprint("%s requested irc client %s", stamp(), cmd));

	"ctcp" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		if(rem == nil)
			return replyerror(m, Ebadctl);
		err = writemsg(ref Timsg.Privmsg(t.name, sprint("\u0001%s\u0001", rem)));
		if(err == nil)
			mwrite(t.name, sprint("%s sent ctcp: %s", stamp(), rem));

	"kick" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		(toks, rem) = tokens(rem, " ", 1);
		if(toks == nil)
			return replyerror(m, "missing nick");
		err = writemsg(ref Timsg.Kick(t.name, hd toks, rem));

	"op" or
	"deop" or
	"ban" or
	"unban" or
	"voice" or
	"devoice" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		way := "+";
		if(cmd[:2] == "de" || cmd[:2] == "un") {
			way = "-";
			cmd = cmd[2:];
		}
		mode := cmd[:1];
		(toks, nil) = tokens(rem, " ", -1);
		while(toks != nil && err == nil) {
			modes: list of string;
			for(i := 0; i < 3 && toks != nil; i++) {
				modes = way+mode::hd toks::modes;
				toks = tl toks;
			}
			err = writemsg(ref Timsg.Mode(t.name, modes));
		}
	"mode" =>
		if(t.id == 0 || !t.ischan)
			return replyerror(m, Enotchan);
		(toks, nil) = tokens(rem, " ", -1);
		err = writemsg(ref Timsg.Mode(t.name, toks));

	"part" or
	"remove" =>
		if(t.id == 0)
			return replyerror(m, Estatus);
		if(cmd == "remove")
			t.remove = 1;
		if(!t.eof) {
			if(state != Connected)
				return replyerror(m, Enocon);
			if(t.ischan) {
				err = writemsg(ref Timsg.Part(t.name));
			} else {
				mwrite(t.name, sprint("you left"));
				shutdown(t);
			}
		} else if(t.remove)
			writefile(eventfile, sprint("del %d\n", t.id));

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
		if(!targets[i].eof)
			shutdown(targets[i]);
	say(sprint("killing pids %d %d", readerpid, writerpid));
	kill(readerpid);
	kill(writerpid);
	kill(nextpingpid);
	kill(pingwatchpid);
	readerpid = writerpid = nextpingpid = pingwatchpid = -1;
}

connectstatus(): string
{
	case state {
	Connected =>	return "connected "+ic.nick;
	Dialing =>	return "dialing";
	Connecting =>	return "connecting";
	Disconnected =>	return "disconnected";
	* =>		return "unknown";
	}
}

# dial with a local hostname (which is translated using /net/cs)
dialfancy(addr: string, fromhost: string): (ref (ref Sys->FD, ref Sys->FD), string)
{
	cfd, dfd: ref Sys->FD;

	csfd := sys->open("/net/cs", Sys->ORDWR);
	if(csfd == nil)
		return (nil, sprint("open /net/cs: %r"));

	buf := array[1024] of byte;
	bindquery := sprint("net!%s!0", fromhost);
	if(sys->fprint(csfd, "%s", bindquery) < 0 || (n := sys->read(csfd, buf, len buf)) <= 0)
		return (nil, sprint("translating %q: %r", bindquery));

	s := string buf[:n];

	(err, bindaddr) := str->splitstrl(s, " ");
	if(bindaddr == nil)
		return (nil, sprint("translating %q: %s", bindquery, err));

	if(sys->fprint(csfd, "%s", addr) < 0 || sys->seek(csfd, big 0, Sys->SEEKSTART) != big 0)
		return (nil, sprint("translating %q: %s", addr, err));

	for(;;) {
		n = sys->read(csfd, buf, len buf);
		if(n <= 0)
			return (nil, sprint("translating %q: %r", addr));
		s = string buf[:n];
		(clonepath, connectaddr) := str->splitstrl(s, " ");
		if(connectaddr == nil)
			continue;

		cfd = sys->open(clonepath, Sys->ORDWR);
		if(cfd == nil || (n = sys->read(cfd, buf, len buf)) <= 0)
			return (nil, sprint("open %s: %r", clonepath));

		connid := int string buf[:n];

		if(sys->fprint(cfd, "bind %s", bindaddr) < 0)
			return (nil, sprint("bind %s: %r", bindaddr));
		if(sys->fprint(cfd, "connect %s", connectaddr) < 0)
			return (nil, sprint("connect %s: %r", connectaddr));

		(protodir, nil) := str->splitstrr(sys->fd2path(cfd), "/");
		dpath := protodir+string connid+"/data";

		dfd = sys->open(dpath, Sys->ORDWR);
		if(dfd != nil)
			break;
	}
	if(dfd == nil)
		return (nil, sprint("could not connect"));
	return (ref (cfd, dfd), nil);
}

ircreader(addr, fromhost, newnick, newpass: string)
{
	dfd, cfd: ref Sys->FD;

	addr = dial->netmkaddr(addr, "net", "6667");
	if(fromhost == nil) {
		say("dialing");
		c := dial->dial(addr, nil);
		if(c == nil) {
			dialerrc <-= sprint("dial %s: %r", addr);
			return;
		}
		dfd = c.dfd;
		cfd = c.cfd;
	} else {
		say("dialing with bind and connect");
		(fds, err) := dialfancy(addr, fromhost);
		if(err != nil) {
			dialerrc <-= "dial: "+err;
			return;
		}
		(cfd, dfd) = *fds;
	}
	sys->fprint(cfd, "keepalive");
	say("connected");

	err: string;
	(ic, err) = Irccon.new(dfd, addr, newnick, newnick, newpass);
	if(err != nil) {
		dialerrc <-= err;
		return;
	}
	spawn ircwriter(pidc := chan of int, dfd);
	say("new ircc");
	wpid := <-pidc;
	dialc <-= (pid(), wpid);

	for(;;) {
		(m, l, merr) := ic.readmsg();
		if(l == nil) {
			ircerrc <-= merr;
			break;
		}
		if(m != nil)
			say("have imsg: "+m.text());
		ircinc <-= (m, l, merr);
	}
}

ircwriter(pidc: chan of int, fd: ref Sys->FD)
{
	pidc <-= pid();
	say("ircwriter");
	for(;;) {
		d := <-ircoutc;
		if(d == nil)
			break;
		if(sys->write(fd, d, len d) != len d) {
			ircerrc <-= sprint("writing irc message: %r");
			break;
		}
	}
}

stamp(): string
{
	tm := dt->local(dt->now());
	if(tflag)
		return sprint("%4d-%02d-%02d %02d:%02d:%02d", 1900+tm.year, 1+tm.mon, tm.mday, tm.hour, tm.min, tm.sec);
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

Fidfile.new(fid: ref Fid, t: ref Target, singlebuf: int): ref Fidfile
{
	f := ref Fidfile(fid, 0, 0, array[0] of ref Tmsg.Read, array[0] of array of byte, singlebuf);
	if(t != nil)
		f.sethist(t, Histdefault);
	return f;
}

Fidfile.write(f: self ref Fidfile, s: string)
{
	f.putdata(s);
	while((m := f.styxop(nil)) != nil)
		srv.reply(m);
}

Fidfile.putdata(f: self ref Fidfile, s: string)
{
	if(f.singlebuf)
		f.a = array[] of {array of byte s};
	else
		f.a = add(f.a, array of byte s);
}

Fidfile.putread(f: self ref Fidfile, m: ref Tmsg.Read)
{
	f.reads = add(f.reads, m);
}

Fidfile.sethist(ff: self ref Fidfile, t: ref Target, n: int)
{
	have := 0;
	ff.histo = 0;
	for(ff.histoff = t.histend; ff.histoff > t.histbegin; ff.histoff--) {
		i := (t.histfirst+(ff.histoff-1-t.histbegin))%len t.hist;
		have += len t.hist[i];
		if(have > n)
			break;
	}
}

Fidfile.styxop(ff: self ref Fidfile, t: ref Target): ref Rmsg
{
	if(len ff.reads == 0)
		return nil;

	if(t == nil) {
		if(len ff.a == 0)
			return nil;
		(r, d) := (ff.reads[0], ff.a[0]);
		n := min(len d, r.count);
		ff.reads = ff.reads[1:];
		if(n == len ff.a[0])
			ff.a = ff.a[1:];
		else
			ff.a[0] = ff.a[0][n:];
		return ref Rmsg.Read(r.tag, d[:n]);
	}

	r := ff.reads[0];

	if(ff.histoff >= t.histend) {
		if(t.eof) {
			ff.reads = ff.reads[1:];
			return ref Rmsg.Read (r.tag, array[0] of byte);
		}
		return nil;
	}
	if(ff.histoff < t.histbegin) {
		if(ff.histo != 0) {
			ff.histo = 0;
			return ref Rmsg.Error(r.tag, "slow read of partial line");
		}
		ff.histoff = t.histbegin;
		ff.histo = 0;
	}
	ff.reads = ff.reads[1:];

	if(r.count == 0)
		return ref Rmsg.Read(r.tag, array[0] of byte);

	# prefer to return whole lines, but at least return something
	d := array[0] of byte;
	for(;;) {
		if(ff.histoff == t.histend)
			break;
		i := (t.histfirst+ff.histoff-t.histbegin)%len t.hist;
		if(len d != 0 && len d+len t.hist[i]-ff.histo > r.count)
			break;
		n := min(len t.hist[i]-ff.histo, r.count-len d);
		nd := array[len d+n] of byte;
		nd[:] = d;
		nd[len d:] = t.hist[i][ff.histo:ff.histo+n];
		d = nd;
		ff.histo += n;
		if(ff.histo == len t.hist[i]) {
			ff.histo = 0;
			ff.histoff++;
		}
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
		0, 0, 0,
		array[0] of string, array[0] of string,
		0, 0, 0, nil, dt->now());
}

Target.putdata(t: self ref Target, s: string)
{
	d := array of byte s;
	t.mtime = dt->now();
	while(t.histlength+len d > Histmax && t.histbegin < t.histend) {
		t.histlength -= len t.hist[t.histfirst];
		t.histbegin++;
		t.histfirst = (t.histfirst+1)%len t.hist;
	}
	t.histend++;
	if(t.histend-t.histbegin > len t.hist)
		t.hist = grow(t.hist, 16);
	t.hist[(t.histfirst+(t.histend-1-t.histbegin))%len t.hist] = d;
	t.histlength += len d;
}

Target.write(t: self ref Target, s: string)
{
	t.putdata(s);
	if(s != nil && t.logfd != nil) {
		o := 0;
		if(tflag)
			o = 2;  # skip type
		if(sys->fprint(t.logfd, "%s", s[o:]) < 0)
			warn(sprint("writing log: %r"));
	}
	for(i := 0; i < len t.data; i++)
		while((m := t.data[i].styxop(t)) != nil)
			srv.reply(m);
}

Target.shutdown(t: self ref Target)
{
	if(!t.eof) {
		writefile(t.data, "");
		writefile(t.users, "");
		t.eof = 1;
	}
}


shutdown(t: ref Target)
{
	t.shutdown();
	if(t.remove)
		writefile(eventfile, sprint("del %d\n", t.id));
	if(t.remove && t.opens == 0)
		targets = del(targets, t);
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
		if(!targets[i].eof && targets[i].lname == lname)
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

sdwrite(name, text: string)
{
	gettarget(name).write("- "+text+"\n");
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
		if(!targets[i].eof)
			targets[i].write(text);
}

writeraw(s: string): string
{
	d := array of byte s;
	if(len d+imsgselflen > Irc->Maximsglen)
		return "line too long";
	alt {
	ircoutc <-= d =>
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
	return (rev(toks), rem);
}

grow[T](d: array of T, n: int): array of T
{
	r := array[len d+n] of T;
	r[:] = d;
	return r;
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

rev[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l::r;
	return r;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

pid(): int
{
	return sys->pctl(0, nil);
}

killgrp(pid: int)
{
	progctl(pid, "killgrp");
}

kill(pid: int)
{
	progctl(pid, "kill");
}

progctl(pid: int, ctl: string)
{
	if(pid >= 0 && (fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE)) != nil)
		sys->fprint(fd, "%s", ctl);
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
