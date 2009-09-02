Irc: module
{
	PATH:	con "/dis/lib/irc.dis";

	init:	fn();

	RPLwelcome:	con 1;
	RPLaway:	con 301;
	RPLchannelmode:	con 324;
	RPLchannelmodechanged:	con 329;
	RPLtopic:	con 332;
	RPLtopicset:	con 333;
	RPLinviting:	con 341;
	RPLnames:	con 353;
	RPLnamesdone:	con 366;
	RPLnickinuse:	con 433;

	RPLwhoisuser:	con 311;
	RPLwhoisserver:	con 312;
	RPLwhoisoperator:	con 313;
	RPLwhoisidle:	con 317;
	RPLendofwhois:	con 318;
	RPLwhoischannels:	con 319;

	RPLnosuchnick:		con 401;
	RPLnosuchchannel:	con 403;
	RPLcannotsendtochan:	con 404;
	RPLtoomanychannels:	con 405;
	RPLwasnosuchnick:	con 406;

	Maximsglen:	con 512;

	ischannel:	fn(name: string): int;
	lowercase:	fn(name: string): string;

	Irccon: adt {
		fd:	ref Sys->FD;
		b:	ref Bufio->Iobuf;
		addr:	string;
		nick, lnick:	string;
		server:	string;

		new:	fn(fd: ref Sys->FD, addr: string, nick, name, pass: string): (ref Irccon, string);
		readmsg:	fn(c: self ref Irccon): (ref Rimsg, string, string);
		writemsg:	fn(c: self ref Irccon, m: ref Timsg): string;
		fromself:	fn(c: self ref Irccon, f: ref From): int;
	};

	From: adt {
		nick, server, user, host: string;

		text:	fn(f: self ref From): string;
	};

	Timsg: adt {
		pick {
		Pass =>
			pass: string;
		Nick or User or Names =>
			name: string;
		Privmsg or Notice =>
			who, m: string;
		Join =>
			where, key: string;
		Away =>
			m: string;
		Part =>
			where: string;
		Topicget =>
			where: string;
		Topicset =>
			where, m: string;
		Quit =>
			m: string;
		Pong =>
			who, m: string;
		Mode =>
			where: string;
			modes: list of string;	# for sending, we do not split between mode and modeargs
		Kick =>
			where, who, m: string;
		Whois =>
			name: string;
		Invite =>
			who, where: string;
		Ping =>
			server:	string;
		}

		pack:	fn(m: self ref Timsg): string;
		text:		fn(m: self ref Timsg): string;
	};

	Rimsg: adt {
		f: ref From;
		cmd:	string;
		pick {
		Nick =>
			name: string;
		Mode =>
			where: string;
			modes: list of (string, list of string);
		Quit or Error or Squit =>
			m: string;
		Join =>
			where: string;
		Part or Topic or Privmsg or Notice =>
			where, m: string;
		Ping =>
			who, m: string;
		Pong =>
			who, m: string;
		Kick =>
			where, who, m: string;
		Invite =>
			who, where: string;
		Unknown or Replytext or Errortext =>
			where: string;	# may be empty
			params: array of string;
		}

		unpack:	fn(s: string): (ref Rimsg, string);
		text:	fn(m: self ref Rimsg): string;
	};
};
