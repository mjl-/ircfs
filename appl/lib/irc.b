implement Irc;

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "irc.m";

# when adding new ones, consider adding it to irc.m too
desttypes := array[] of {
	301, 311, 312, 313, 317, 318, 319,	# nick as first token
	324, 325, 329, 331, 332, 333, 341, 346, 347, 348, 349, 366, 367, 368,	# channel as first token
	401, 403, 404, 405, 406, 467, 471, 473, 474, 475, 476, 477, 478, 482,	# nick or channel as first token
};


init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	bufio->open("/dev/null", Bufio->OREAD);  # hack to get bufio loaded correctly
	str = load String String->PATH;
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

liststr(l: list of string): string
{
	if(l == nil)
		return "";
	s := "";
	for(; l != nil; l = tl l)
		s += sprint("%q, ", hd l);
	return "("+s[0:len s-2]+")";
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l::r;
	return r;
}

Irccon.new(fd: ref Sys->FD, addr, nick, name, pass: string): (ref Irccon, string)
{
	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		return (nil, sprint("bufio fopen: %r"));

	c := ref Irccon(fd, b, addr, nick, lowercase(nick), nil);
	if(pass != nil)
		err := c.writemsg(ref Timsg.Pass(pass));
	if(err == nil) err = c.writemsg(ref Timsg.Nick(nick));
	if(err == nil) err = c.writemsg(ref Timsg.User(name));
	if(err != nil)
		return (nil, err);
	return (c, nil);
}

Irccon.readmsg(c: self ref Irccon): (ref Rimsg, string, string)
{
	l := c.b.gets('\n');
	if(l == nil)
		return (nil, nil, sprint("%r"));
	(m, err) := Rimsg.unpack(l);
	return (m, l, err);
}

Irccon.writemsg(c: self ref Irccon, m: ref Timsg): string
{
	d := array of byte m.pack();
	if(sys->write(c.fd, d, len d) != len d)
		return sprint("writing message: %r");
	return nil;
}

Irccon.fromself(c: self ref Irccon, f: ref From): int
{
	return c.lnick == lowercase(f.nick);
}

Timsg.pack(m: self ref Timsg): string
{
	s := "";
	pick mm := m {
	Pass =>	s += sprint("PASS %s", mm.pass);
	Nick =>	s += sprint("NICK %s", mm.name);
	User =>	s += sprint("USER none 0 * :%s", mm.name);
	Whois =>	s += sprint("WHOIS %s", mm.name);
	Privmsg =>	s += sprint("PRIVMSG %s :%s", mm.who, mm.m);
	Notice =>	s += sprint("NOTICE %s :%s", mm.who, mm.m);
	Join =>		s += sprint("JOIN %s", mm.where);
			if(mm.key != nil)
				s += " "+mm.key;
	Away =>		s += sprint("AWAY :%s", mm.m);
	Topicget =>	s += sprint("TOPIC %s", mm.where);
	Topicset =>	s += sprint("TOPIC %s :%s", mm.where, mm.m);
	Part =>		s += sprint("PART %s", mm.where);
	Quit =>		s += sprint("QUIT :%s", mm.m);
	Pong =>		s += sprint("PONG %s %s", mm.who, mm.m);
	Mode =>		s += sprint("MODE %s", mm.where);
			for(l := mm.modes; l != nil; l = tl l)
				s += sprint(" %s", hd l);
	Kick =>		s += sprint("KICK %s %s %s", mm.where, mm.who, mm.m);
	Names =>	s += sprint("NAMES %s", mm.name);
	Invite =>	s += sprint("INVITE %s %s", mm.who, mm.where);
	Ping =>		s += sprint("PING %s", mm.server);
	* =>	raise "missing case";
	}
	s += "\r\n";
	return s;
}

Timsg.text(m: self ref Timsg): string
{
	s := "";
	s += "Timsg.";
	pick mm := m {
	Pass =>		s += sprint("Pass(%q)", mm.pass);
	Nick =>		s += sprint("Nick(%q)", mm.name);
	User =>		s += sprint("User(%q)", mm.name);
	Whois =>	s += sprint("Whois(%q)", mm.name);
	Privmsg =>	s += sprint("Privmsg(%q, %q)", mm.who, mm.m);
	Notice =>	s += sprint("Notice(%q, %q)", mm.who, mm.m);
	Join =>		s += sprint("Join(%q)", mm.where);
	Away =>		s += sprint("Away(%q)", mm.m);
	Topicget =>	s += sprint("Topic(%q)", mm.where);
	Topicset =>	s += sprint("Topic(%q, %q)", mm.where, mm.m);
	Part =>		s += sprint("Part(%q)", mm.where);
	Quit =>		s += sprint("Quit(%q)", mm.m);
	Pong =>		s += sprint("Pong(%q, %q)", mm.who, mm.m);
	Mode =>		s += sprint("Mode(%q", mm.where);
			for(l := mm.modes; l != nil; l = tl l)
				s += sprint(", %q", hd l);
			s += ")";
	Kick =>		s += sprint("Kick(%q, %q, %q", mm.where, mm.who, mm.m);
	Names =>	s += sprint("Names(%q)", mm.name);
	Invite =>	s += sprint("Invite(%q, %q)", mm.who, mm.where);
	Ping =>		s += sprint("Ping(%q)", mm.server);
	* =>	raise "missing case";
	}
	return s;
}


Rimsg.text(m: self ref Rimsg): string
{
	s := "";
	if(m.f != nil)
		s += m.f.text()+" ";
	s += "Rimsg.";
	pick mm := m {
	Nick =>	s += sprint("Nick(%q)", mm.name);
	Mode =>	s += sprint("Mode(%q", mm.where);
		for(l := mm.modes; l != nil; l = tl l)
			s += sprint(", %q, %s", (hd l).t0, liststr((hd l).t1));
		s += ")";
	Quit =>	s += sprint("Quit(%q)", mm.m);
	Error =>
		s += sprint("Error(%q)", mm.m);
	Squit =>
		s += sprint("Squit(%q)", mm.m);
	Join => s += sprint("Join(%q)", mm.where);
	Part =>	s += sprint("Part(%q, %q)", mm.where, mm.m);
	Topic =>	s += sprint("Topic(%q, %q)", mm.where, mm.m);
	Privmsg =>	s += sprint("Privmsg(%q, %q)", mm.where, mm.m);
	Notice =>	s += sprint("Notice(%q, %q)", mm.where, mm.m);
	Ping =>	s += sprint("Ping(%q, %q)", mm.who, mm.m);
	Pong =>	s += sprint("Pong(%q, %q)", mm.who, mm.m);
	Kick =>	s += sprint("Kick(%q, %q, %q)", mm.where, mm.who, mm.m);
	Invite =>	s += sprint("Invite(%q, %q)", mm.who, mm.where);
	Unknown or
	Replytext or
	Errortext =>
		which := "";
		case tagof m {
		Rimsg.Unknown =>	which = "Unknown";
		Rimsg.Replytext =>	which = "Replytext";
		Rimsg.Errortext =>	which = "Errortext";
		}
		l := "";
		for(i := 0; i < len mm.params; i++)
			l += " "+sprint("%q", mm.params[i]);
		if(len mm.params > 0)
			l = l[1:];
		s += sprint("%s(%q, %s)", which, mm.cmd, l);
	* =>
		raise "missing case";
	}
	return s;
}

Rimsg.unpack(s: string): (ref Rimsg, string)
{
	pre, cmd: string;
	f: ref From;

	if(len s <= 2 || s[len s-2: len s] != "\r\n")
		return (nil, "parsing: missing carriage return and/or newline");
	s = s[:len s-2];

	# parse possible prefix
	if(s[0] == ':') {
		(pre, s) = str->splitl(s, " ");
		if(s == nil || len s[1:] == 0)
			return (nil, "parsing: message contains prefix but no command");
		f = parsefrom(pre[1:]);
		s = s[1:];
	}

	(cmd, s) = str->splitl(s, " ");
	if(len cmd == 0)
		return (nil, "parsing: command is missing");
	case cmd {
	"NICK" or
	"MODE" or
	"QUIT" or
	"JOIN" or
	"PART" or
	"TOPIC" or
	"KICK" =>
		if(f == nil)
			return (nil, "missing 'from'");
	}
	if(s != nil)
		s = s[1:];

	params := array[0] of string;
	while(s != nil && len s > 0) {
		tmp := array[len params+1] of string;
		tmp[:] = params;
		params = tmp;

		if(s[0] == ':') {
			params[len params-1] = s[1:];
			break;
		} else {
			(params[len params-1], s) = str->splitl(s, " ");
			if(s != nil)
				s = s[1:];
		}
	}

	case cmd {
	"NICK" =>
		if(len params != 1)
			return (nil, "bad nick message, missing param");
		return (ref Rimsg.Nick(f, cmd, params[0]), nil);
	"MODE" =>
		if(len params < 2)
			return (nil, "bad params for mode");
		modes: list of (string, list of string);
		i := 1;
		while(i < len params) {
			if(!str->prefix("-", params[i]) && !str->prefix("+", params[i]))
				return (nil, "bad params for mode");
			mode := params[i++];
			modeparams: list of string;
			while(i < len params && !str->prefix("-", params[i]) && !str->prefix("+", params[i]))
				modeparams = params[i++]::modeparams;
			modes = (mode, rev(modeparams))::modes;
		}
		return (ref Rimsg.Mode(f, cmd, params[0], modes), nil);
	"QUIT" or
	"ERROR" or
	"SQUIT" =>
		if(len params > 1)
			return (nil, "bad params for quit/error/squit");
		m := "";
		if(len params == 1)
			m = params[0];
		case cmd {
		"QUIT" =>	return (ref Rimsg.Quit(f, cmd, m), nil);
		"ERROR" =>	return (ref Rimsg.Error(f, cmd, m), nil);
		"SQUIT" =>	return (ref Rimsg.Squit(f, cmd, m), nil);
		}
	"JOIN" =>
		if(len params != 1)
			return (nil, "bad params for join");
		return (ref Rimsg.Join(f, cmd, params[0]), nil);
	"PART" or
	"TOPIC" or
	"PRIVMSG" or
	"NOTICE" =>
		m := "";
		case len params {
		1 =>	;
		2 =>	m = params[1];
		* =>	return (nil, "bad params for part");
		}
		case cmd {
		"PART" =>	return (ref Rimsg.Part(f, cmd, params[0], m), nil);
		"TOPIC" =>	return (ref Rimsg.Topic(f, cmd, params[0], m), nil);
		"PRIVMSG" =>	return (ref Rimsg.Privmsg(f, cmd, params[0], m), nil);
		"NOTICE" =>	return (ref Rimsg.Notice(f, cmd, params[0], m), nil);
		}
	"PING" =>
		case len params {
		1 =>	return (ref Rimsg.Ping(f, cmd, params[0], nil), nil);
		2 =>	return (ref Rimsg.Ping(f, cmd, params[0], params[1]), nil);
		* =>	return (nil, "bad params for ping");
		}
	"PONG" =>
		case len params {
		1 =>	return (ref Rimsg.Pong(f, cmd, params[0], nil), nil);
		2 =>	return (ref Rimsg.Pong(f, cmd, params[0], params[1]), nil);
		* =>	return (nil, "bad params for pong");
		}
	"KICK" =>
		case len params {
		2 =>	return (ref Rimsg.Kick(f, cmd, params[0], params[1], nil), nil);
		3 =>	return (ref Rimsg.Kick(f, cmd, params[0], params[1], params[2]), nil);
		* =>	return (nil, "bad params for kick");
		}
	"INVITE" =>
		case len params {
		2 =>	return (ref Rimsg.Invite(f, cmd, params[0], params[1]), nil);
		* =>	return (nil, "bad params for invite");
		}
	* =>
		if(str->take(cmd, "0-9") != cmd || len cmd != 3)
			return (ref Rimsg.Unknown(f, cmd, nil, params), nil);

		where: string;
		id := int cmd;
		for(i := 0; i < len desttypes; i++)
			if(desttypes[i] == id && len params >= 1) {
				where = params[1];
				params = params[2:];
				break;
			}
		if(id == 353 && len params >= 3)
			return (ref Rimsg.Replytext(f, cmd, params[2], params[1:]), nil);
		if(where == nil)
			params = params[1:];
		if(cmd[0] == '4' || cmd[0] == '5')
			return (ref Rimsg.Errortext(f, cmd, where, params), nil);
		return (ref Rimsg.Replytext(f, cmd, where, params), nil);
	}
	return (nil, "unhandled irc message?");
}

From.text(f: self ref From): string
{
	if(f.host == nil || f.user == nil)
		return f.server;
	return sprint("%s!%s@%s", f.nick, f.user, f.host);
}

parsefrom(s: string): ref From
{
	f: From;
	host, user: string;

	(s, host) = str->splitl(s, "@");
	if(host == nil) {
		f.nick = f.server = s;
		return ref f;
	}

	f.host = host[1:];
	(s, user) = str->splitl(s, "!");
	if(user == nil) {
		f.nick = s;
		return ref f;
	}

	f.user = user[1:];
	f.nick = s;
	return ref f;
}
