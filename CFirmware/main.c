#include <stdio.h>
#include <string.h>
#include <malloc.h>

#include "minisoc_hardware.h"
#include "ints.h"
#include "ps2.h"
#include "keyboard.h"
#include "textbuffer.h"
#include "spi.h"
#include "fat.h"

short *FrameBuffer;
extern short pen;
extern void DrawIteration();

static short framecount=0;
short MouseX=0,MouseY=0,MouseZ=0,MouseButtons=0;
short mousetimeout=0;

void vblank_int()
{
	static short mousemode=0;
	char a=0;
	int yoff;
	framecount++;
	if(framecount==959)
		framecount=0;
	if(framecount>=480)
		yoff=959-framecount;
	else
		yoff=framecount;
	HW_VGA_L(FRAMEBUFFERPTR)=(unsigned long)(&FrameBuffer[yoff*640]);

	while(PS2MouseBytesReady()>=(3+mousemode))	// FIXME - institute some kind of timeout here to re-sync if sync lost.
	{
		short nx;
		short w1,w2,w3,w4;
		w1=PS2MouseRead();
		w2=PS2MouseRead();
		w3=PS2MouseRead();
		if(mousemode)	// We're in 4-byte packet mode...
		{
			w4=PS2MouseRead();
			if(w4&8)	// Negative
				MouseZ-=(w4^15)&15;
			else
				MouseZ+=w4&15;
		}
		MouseButtons=w1;
//		printf("%02x %02x %02x\n",w1,w2,w3);
		if(w1 & (1<<5))
			w3|=0xff00;
		if(w1 & (1<<4))
			w2|=0xff00;
//			HW_PER(PER_HEX)=(w2<<8)|(w3 & 255);

		nx=MouseX+w2;
		if(nx<0)
			nx=0;
		if(nx>639)
			nx=639;
		MouseX=nx;

		nx=MouseY-w3;
		if(nx<0)
			nx=0;
		if(nx>479)
			nx=479;
		MouseY=nx;

		mousetimeout=0;
	}
	HW_VGA(SP0XPOS)=MouseX;
	HW_VGA(SP0YPOS)=MouseY;

	// Clear any incomplete packets, to resync the mouse if comms break down.
	if(PS2MouseBytesReady())
	{
		++mousetimeout;
		if(mousetimeout==20)
		{
			while(PS2MouseBytesReady())
				PS2MouseRead();
			mousetimeout=0;
			mousemode^=1;	// Toggle 3/4 byte packets
		}
	}

	// Receive any keystrokes
	if(PS2KeyboardBytesReady())
		a=HandlePS2RawCodes();
	if(a)
		putchar(a);
}

void timer_int()
{
	if(HW_PER(PER_TIMER_CONTROL) & (1<<PER_TIMER_TR5))
		mousetimeout=1;
//	puts("Timer int received\n");
}


void SetTimeout(int delay)
{
	HW_PER(PER_TIMER_CONTROL)=(1<<PER_TIMER_EN5);
	HW_PER(PER_TIMER_DIV5)=delay;
}


void AddMemory()
{
	size_t low;
	size_t size;
	low=(size_t)&heap_low;
	low+=7;
	low&=0xfffffff8; // Align to SDRAM burst boundary
	size=1<<HW_PER(PER_CAP_RAMSIZE);
	size-=low;
	printf("Heap_low: %lx, heap_size: %lx\n",low,size);
	malloc_add((void*)low,size);
}


extern DIRENTRY DirEntry[MAXDIRENTRIES];
extern unsigned char sort_table[MAXDIRENTRIES];
extern unsigned char nDirEntries;
extern unsigned char iSelectedEntry;
extern unsigned long iCurrentDirectory;
extern char DirEntryLFN[MAXDIRENTRIES][261];
char DirEntryInfo[MAXDIRENTRIES][5]; // disk number info of dir entries
char DiskInfo[5]; // disk number info of selected entry

// print directory contents
void PrintDirectory(void)
{
	unsigned char i;
	unsigned char k;
	unsigned long len;
	char *lfn;
	char *info;
	char *p;
	unsigned char j;

	for (i = 0; i < 8; i++)
	{
		k = sort_table[i]; // ordered index in storage buffer
		lfn = DirEntryLFN[k]; // long file name pointer
		if (lfn[0]) // item has long name
		{
			puts(lfn);
		}
		else  // no LFN
		{
			puts(&DirEntry[k].Name);
		}

		if (DirEntry[k].Attributes & ATTR_DIRECTORY) // mark directory with suffix
			puts("<DIR>\n");
		else
			puts("\n");
	}
}


#define CYCLE_LFSR {lfsr<<=1; if(lfsr&0x400000) lfsr|=1; if(lfsr&0x200000) lfsr^=1;}
void DoMemcheckCycle(unsigned int *p)
{
	int i;
	static int lfsr=1234;
	unsigned int lfsrtemp=lfsr;
	for(i=0;i<65536;++i)
	{
		unsigned int w=lfsr&0xfffff;
		unsigned int j=lfsr&0xfffff;
		CYCLE_LFSR;
		unsigned int x=lfsr&0xfffff;
		unsigned int k=lfsr&0xfffff;
		p[j]=w;
		p[k]=x;
		CYCLE_LFSR;
	}
	lfsr=lfsrtemp;
	for(i=0;i<65536;++i)
	{
		unsigned int w=lfsr&0xfffff;
		unsigned int j=lfsr&0xfffff;
		CYCLE_LFSR;
		unsigned int x=lfsr&0xfffff;
		unsigned int k=lfsr&0xfffff;
		if(p[j]!=w)
		{
			printf("Error at %x\n",w);
			printf("expected %x, got %x\n",w,p[j]);
		}
		if(p[k]!=x)
		{
			printf("Error at %x\n",w);
			printf("expected %x, got %x\n",w,p[j]);
		}
		CYCLE_LFSR;
	}
}


void c_entry()
{
	enum mainstate_t {MAIN_IDLE,MAIN_LOAD,MAIN_MEMCHECK,MAIN_RECTANGLES};
	fileTYPE file;
	unsigned char *fbptr;
	ClearTextBuffer();

	AddMemory();

	PS2Init();
	SetSprite();

	FrameBuffer=(short *)malloc(sizeof(short)*640*960);
	HW_VGA_L(FRAMEBUFFERPTR)=FrameBuffer;

	memset(FrameBuffer,0,sizeof(short)*640*960);

	EnableInterrupts();

	while(PS2MouseRead()>-1)
		; // Drain the buffer;
	PS2MouseWrite(0xf4);

	SetIntHandler(PER_INT_TIMER,&timer_int);
	SetTimeout(10000);
	while(PS2MouseRead()!=0xfa && mousetimeout==0)
		; // Read the acknowledge byte

	if(mousetimeout)
		puts("Mouse timed out\n");

	// Don't set the VBlank int handler until the mouse has been initialised.
	SetIntHandler(VGA_INT_VBLANK,&vblank_int);

	puts("Initialising SD card\n");
	spi_init();

	FindDrive();
	puts("FindDrive() returned\n");

	ChangeDirectory(DIRECTORY_ROOT);
	puts("Changed directory\n");

	ScanDirectory(SCAN_INIT, "*", 0);
	puts("Scanned directory\n");
//	PrintDirectory();

	enum mainstate_t mainstate=MAIN_LOAD;

	while(1)
	{
		if(TestKey(KEY_F1))
		{
			mainstate=MAIN_LOAD;
			puts("Switching to image mode\n");
		}
		if(TestKey(KEY_F2))
		{
			mainstate=MAIN_MEMCHECK;
			puts("Switching to Memcheck mode\n");
		}
		if(TestKey(KEY_F3))
		{
			mainstate=MAIN_RECTANGLES;
			puts("Switching to Rectangles mode\n");
		}

		// Main loop iteration.
		switch(mainstate)
		{
			case MAIN_IDLE:
				break;
			case MAIN_LOAD:
				if(FileOpen(&file,"TEST    IMG"))
				{
					fbptr=FrameBuffer;
					short imgsize=file.size/512;
					int c=0;
					while(c<=((640*960*2-1)/512) && c<imgsize)
					{
						FileRead(&file, fbptr);
						c+=1;
						FileNextSector(&file);
						fbptr+=512;
					}
					puts("\r\nWelcome to TG68MiniSOC, a minimal System-on-Chip,\r\nbuilt around Tobias Gubener's TG68k soft core processor.\r\n");
					puts("Press F1, F2 or F3 to change test mode.\r\n");
				}
				else
					printf("Couldn't load test.img\n");
				mainstate=MAIN_IDLE;
				break;
			case MAIN_MEMCHECK:
				DoMemcheckCycle((unsigned int *)FrameBuffer);
				break;
			case MAIN_RECTANGLES:
				if(MouseButtons&1)
					pen+=0x400;
				if(MouseButtons&2)
					pen-=0x400;
				DrawIteration();
				break;
		}
	}
}

