/*
 * Copyright (C) 2011 Ermal Lu�i
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
 * OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

%{
#include <sys/types.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ctype.h>
#include <err.h>
#include <errno.h>
#include <unistd.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "filterdns.h"

struct file {
	FILE			*stream;
	char			*name;
	int			 lineno;
	int			 error;
};

static struct file *file;
int		 yyparse(void);
int		 yylex(void);
int		 yyerror(const char *, ...);
int		 kw_cmp(const void *, const void *);
int		 lookup(char *);
int		 lgetc(int);
int		 lungetc(int);
int		 findeol(void);

int      atoul(char *, u_long *);

static int errors = 0;

typedef struct {
	union {
		int			number;
		char			*string;
	} v;
	int lineno;
} YYSTYPE;

%}

%token	IPFW PF PIPE ERROR CMD
%token	<v.string>	STRING
%token	<v.number>	NUMBER
%type	<v.number>	ftype
%type	<v.number>	pipe
%type	<v.string>	command

%%

grammar		: /* empty */
		| grammar '\n'
		| grammar dnsrule '\n'
		| grammar error '\n' { errors++; }
		;

dnsrule		: ftype STRING STRING pipe command {
			struct thread_data *thr = NULL;
			u_long  ulval;

			if ($1 != IPFW_TYPE && $1 != PF_TYPE) {
				yyerror("Wrong configuration parameters");
				YYERROR;
			}
			if (thr == NULL) {
				thr = calloc(1, sizeof(*thr));
				if (thr == NULL) {
					yyerror("Filterdns, could not allocate memory");
					YYERROR;
				}
				thr->exit = 0;
				thr->hostname = strdup($2);
				free($2);
				if ($1 == IPFW_TYPE) {
					thr->type = IPFW_TYPE;
					if (atoul($3, &ulval) == -1) {
						free($3);
						yyerror("%s is not a number", $3);
						YYERROR;
					} else
						thr->tablenr = ulval;
				} else if ($1 == PF_TYPE) {
					thr->type = PF_TYPE;
				}
				thr->tablename = strdup($3);
				free($3);

				if ($4)
					thr->pipe = $4;
				if ($5) {
					thr->cmd = strdup($5);
					free($5);
				} 
				TAILQ_INIT(&thr->rnh); 
				TAILQ_INIT(&thr->static_rnh); 
				TAILQ_INSERT_TAIL(&thread_list, thr, next);
			}
		}
		| CMD STRING command {
			struct thread_data *thr = NULL;

			if (!$3) {
				yyerror("Command is mandatory on CMD type directive");
				YYERROR;
			}
			thr = calloc(1, sizeof(*thr));
			if (thr == NULL) {
				yyerror("Filterdns, could not allocate memory");
				YYERROR;
			}
			thr->hostname = strdup($2);
			free($2);
			thr->type = CMD_TYPE;
			thr->cmd = strdup($3);
			free($3);
			thr->tablename = NULL;

			TAILQ_INIT(&thr->rnh); 
			TAILQ_INIT(&thr->static_rnh); 
                        TAILQ_INSERT_TAIL(&thread_list, thr, next);
		}
		;

ftype		: IPFW { $$ = IPFW_TYPE; }
		| PF { $$ = PF_TYPE; }
		;

command		: /* empty */ { $$ = NULL; }
		| STRING {$$ = $1; }
		;

pipe		: /* empty */ { $$ = 0; }
		| PIPE STRING {
			u_long  ulval;

                        if (atoul($2, &ulval) == -1) {
                                yyerror("%s is not a number", $2);
                                free($2);
                                YYERROR;
                        } else {
                                $$ = ulval;
                                free($2);
                        }
		}
		;

%%

struct keywords {
	const char	*k_name;
	int		 k_val;
};

int
yyerror(const char *fmt, ...)
{
	va_list	ap;

	file->error++;
	va_start(ap, fmt);
	fprintf(stderr, "%s:%d: ", file->name, yylval.lineno);
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	return (0);
}

int
kw_cmp(const void *k, const void *e)
{
	return (strcmp(k, ((const struct keywords *)e)->k_name));
}

int
lookup(char *s)
{
	/* this has to be sorted always */
	static const struct keywords keywords[] = {
		{"cmd",			CMD},
		{"ipfw",		IPFW},
		{"pf",			PF},
		{"pipe",		PIPE},
	};
	const struct keywords	*p;

	p = bsearch(s, keywords, sizeof(keywords)/sizeof(keywords[0]),
	    sizeof(keywords[0]), kw_cmp);

	if (p)
		return (p->k_val);
	else
		return (STRING);
}

#define MAXPUSHBACK	128

char	*parsebuf;
int	 parseindex;
char	 pushback_buffer[MAXPUSHBACK];
int	 pushback_index = 0;

int
lgetc(int quotec __unused)
{
	int		c, next;

	if (parsebuf) {
		/* Read character from the parsebuffer instead of input. */
		if (parseindex >= 0) {
			c = parsebuf[parseindex++];
			if (c != '\0')
				return (c);
			parsebuf = NULL;
		} else
			parseindex++;
	}

	if (pushback_index)
		return (pushback_buffer[--pushback_index]);

#if 0
	if (quotec) {
		if ((c = getc(file->stream)) == EOF) {
			yyerror("reached end of file while parsing "
			    "quoted string");
			return (EOF);
		}
		return (c);
	}
#endif

	while ((c = getc(file->stream)) == '\\') {
		next = getc(file->stream);
		if (next != '\n') {
			c = next;
			break;
		}
		yylval.lineno = file->lineno;
		file->lineno++;
	}

	if (c == '\t' || c == ' ') {
                /* Compress blanks to a single space. */
                do {
                        c = getc(file->stream);
                } while (c == '\t' || c == ' ');
                ungetc(c, file->stream);
                c = ' ';
        }

	return (c);
}

int
lungetc(int c)
{
	if (c == EOF)
		return (EOF);
	if (parsebuf) {
		parseindex--;
		if (parseindex >= 0)
			return (c);
	}
	if (pushback_index < MAXPUSHBACK-1)
		return (pushback_buffer[pushback_index++] = c);
	else
		return (EOF);
}

int
findeol(void)
{
	int	c;

	parsebuf = NULL;
	pushback_index = 0;

	/* skip to either EOF or the first real EOL */
	while (1) {
#if 0
		if (pushback_index)
			c = pushback_buffer[--pushback_index];
		else
#endif
			c = lgetc(0);
		if (c == '\n') {
			file->lineno++;
			break;
		}
		if (c == EOF)
			break;
	}
	return (ERROR);
}

int
yylex(void)
{
	char	 buf[8096];
	char	*p;
	int	 quotec, next, c;
	int	 token;

	p = buf;
	while ((c = lgetc(0)) == ' ' || c == '\t')
		; /* nothing */

	yylval.lineno = file->lineno;
	if (c == '#')
		while ((c = lgetc(0)) != '\n' && c != EOF)
			; /* nothing */
	switch (c) {
	case '\'':
	case '"':
		quotec = c;
		while (1) {
			if ((c = lgetc(quotec)) == EOF)
				return (0);
			if (c == quotec) {
				*p = '\0';
				break;
			} else if (c == '\n') {
				file->lineno++;
				continue;
			} else if (c == '\\') {
				if ((next = lgetc(quotec)) == EOF)
					return (0);
				if (next == quotec || c == ' ' || c == '\t')
					c = next;
				else if (next == '\n')
					continue;
				else
					lungetc(next);
			}
			if (p + 1 >= buf + sizeof(buf) - 1) {
				yyerror("string too long");
				return (findeol());
			}
			*p++ = (char)c;
		}
		yylval.v.string = strdup(buf);
		if (yylval.v.string == NULL)
			err(1, "yylex: strdup");
		return (STRING);
	}

#define allowed_in_string(x) \
	(isalnum(x) || (ispunct(x) && x != '(' && x != ')' && \
	x != '{' && x != '}' && \
	x != '!' && x != '=' && x != '#' && \
	x != ','))

	if (isalnum(c) || c == ':' || c == '_') {
		do {
			*p++ = c;
			if ((unsigned)(p-buf) >= sizeof(buf)) {
				yyerror("string too long");
				return (findeol());
			}
		} while ((c = lgetc(0)) != EOF && (allowed_in_string(c)));
		lungetc(c);
		*p = '\0';
		if ((token = lookup(buf)) == STRING)
			if ((yylval.v.string = strdup(buf)) == NULL)
				err(1, "yylex: strdup");
		return (token);
	}
	if (c == '\n') {
		yylval.lineno = file->lineno;
		file->lineno++;
	}
	if (c == EOF)
		return (0);
	return (c);
}

int
parse_config(char *filename)
{
	if (filename == NULL)
		return (-1);
	if ((file = calloc(1, sizeof(struct file))) == NULL) {
		warnx("maaloc");
		return (-1);
	}
	if ((file->name = strdup(filename)) == NULL) {
		warnx("malloc strdup");
		free(file);
		return (-1);
	}
	if ((file->stream = fopen(file->name, "r")) == NULL) {
		warnx("open file");
		if (file->stream)
			fclose(file->stream);
		free(file->name);
		free(file);
		return (-1);
	}
	file->lineno = 1;

	yyparse();
	errors = file->error;
	if (errors)
		return (-1);

	return (0);
}

int
atoul(char *s, u_long *ulvalp)
{
        u_long   ulval;
        char    *ep;

        errno = 0;
        ulval = strtoul(s, &ep, 0);
        if (s[0] == '\0' || *ep != '\0')
                return (-1);
        if (errno == ERANGE && ulval == ULONG_MAX)
                return (-1);
        *ulvalp = ulval;
        return (0);
}
