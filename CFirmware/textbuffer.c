#include <stdio.h>
#include <stdarg.h>

#include "minisoc_hardware.h"
#include "textbuffer.h"

#define text_rows 25
#define text_cols 76

char *VGACHARBUFFER=(char *)VGACHARBUFFERBASE;

static short row=0, col=0;

#define toaddr(r,c) (VGACHARBUFFER+text_cols*r+c)

static void scroll()
{
	int i=0;
	unsigned short *s=(unsigned short *)toaddr(1,0);
	unsigned short *d=(unsigned short *)toaddr(0,0);
	for(i=0;i<(text_rows*text_cols/2);++i)
		*d++=*s++;
	col=0;
	row=text_rows-1;
}

void charbuffer_write(const char *msg)
{
	while(*msg)
	{
		char *p=toaddr(row,col);
		while(row<text_rows)
		{
			char c=*msg++;
			if(!c)
				return;
			if(c=='\b' && col>0)
			{
				--p;
				*p=' ';
				--col;
			}
			else if(c=='\n')
			{
				++row;
				col=0;
			}
			else
			{
				*p++=c;
				if(++col==text_cols)
				{
					col=0;
					++row;
				}
			}
			if(row==text_rows)
				scroll();
		}
	}
}


char buf[256];

int printf(const char *fmt,...)
{
	va_list ap;
	va_start(ap, fmt);
	int num = vsnprintf(buf, 256, fmt, ap);
	va_end(ap);
	puts(buf);
	
	return num;
}

int putchar(int c)
{
	char tmp[2];
	tmp[0]=c;
	tmp[1]=0;
	charbuffer_write(tmp);
	return 1;
}

int puts(const char *str)
{
	charbuffer_write(str);
	return 0;
}

void ClearTextBuffer()
{
	int i=0;
	long *p=(long *)VGACHARBUFFER;
	for(i=0;i<2048;i+=4)
		*p++=0;
}
