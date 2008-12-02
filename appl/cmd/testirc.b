implement Testirc;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "irc.m";
	irc: Irc;
	Ircc, Timsg, Rimsg, From: import irc;

dflag: int;
addr: string;

Testirc: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	irc = load Irc Irc->PATH;
	irc->init(bufio);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-a addr]");
	while((c := arg->opt()) != 0)
		case c {
		'a' =>	addr = arg->earg();
		'd' =>	dflag++;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 0)
		arg->usage();

	say("dialing");
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		fail(sprint("dial %s: %r", addr));
	say("connected");

	(ic, err) := Ircc.new(conn.dfd, addr, "itestirc", "itestirc");
	if(err != nil)
		fail(err);
	say("new ircc");

	for(;;) {
		say("reading...");
		(m, line, merr) := ic.readmsg();
		if(merr != nil)
			fail(merr);
		if(m == nil)
			fail("eof");
		say("have message: "+m.text());
		pick mm := m {
		Ping =>
			say("have ping");
			err = ic.writemsg(ref Timsg.Pong(mm.who, mm.m));
			if(err != nil)
				fail(sprint("writing pong"));
			say("wrote pong");
		}
	}
}

say(s: string)
{
	if(dflag)
		sys->fprint(sys->fildes(2), "%s\n", s);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
	raise "fail:"+s;
}
