library ieee;
use ieee.std_logic_1164.all;
use IEEE.numeric_std.ALL;

-- VGA controller
-- a module to handle VGA output

-- a wrapper that collects together pieces of the video controller into a
-- convenient module.
-- Contains the following:

--   Timings generator (thanks to Peter Wendrech of Syntiac for this)

--   2-bit dithering, currently hardcoded to create 4-bit output from 6-bit input.
--     (designed for 16-bit 5-6-5 display mode).

--   VGA cache, designed to accept 64-bit (4-pixel) bursts from RAM controller.
--     (TODO: redesign VGA cache using M4K)

--   Character ROM and RAM

--   Text overlay window.

--   CPU-accessible registers to control most of the above.

--   Registers include:
-- 0 / 2   Framebuffer Address - hi and low
--     4   Even row modulo
--     6   Odd row modulo (allows scandoubling)

--     8  HTotal
--     A  HSize (typically 640)
--     C  HBStart
--     E  HBStop

--    10  VTotal
--    12  VSize (typically 480)
--    14  VBStart
--    16  VBStop

--    18  Control:
--     0  Visible
--     1  Resolution - high, low  - alternatively could make pixel clock programmable...
--     7  Character overlay on/off

--   Character buffer (2048 bytes)


-- Present the following signals to the SOC:
--	clk : in std_logic;
--	reset : in std_logic;

--	reg_addr_in : in std_logic_vector(10 downto 0);
--	reg_rw : std_logic;
--	reg_uds : std_logic;	-- only affects char buffer
--	reg_lds : std_logic;

--		sdr_addrout : buffer std_logic_vector(23 downto 0); -- to SDRAM
--		sdr_datain : in std_logic_vector(15 downto 0);	-- from SDRAM
--		fill : in std_logic; -- High when data is being written from SDRAM controller
--		req : buffer std_logic -- Request service from SDRAM controller
--    refresh : out std_logic -- tells the SDRAM controller to do a refresh cycle.

--		hsync : out std_logic -- to monitor
--		vsync : out std_logic -- to monitor
--    vblank_int : out std_logic  -- A momentary pulse that the Interrupt controller can use.
--		red : out std_logic_vector(4 downto 0);		-- 16-bit 5-6-5 output
--		green : out std_logic_vector(5 downto 0);
--		blue : out std_logic_vector(4 downto 0);


-- Theory of operation of the cache

--Need a VGA cache that will keep up with 1 word per 4-cycles.
--The SDRAM controller runs on a 16-cycle phase, and shifts 4 words per burst, so
--we will saturate one port of the SDRAM controller as written
--The other port can perform operations when the bank is not equal to either
--the current or next bank used by the VGA cache.
--To this end we will hardcode a framebuffer pointer, and have a "new frame" signal which will
--reset this hardcoded pointer.
--
--We will have three buffers, each 4 words in size; the first is the current data, which will
-- be clocked out one word at a time.
--
--Need a req signal which will be activated at the start of each pixel.
--case counter is
--	when "00" =>
--		vgadata<=buf1(63 downto 48);
--	when "01" =>
--		vgadata<=buf1(47 downto 32);
--	when "02" =>
--		vgadata<=buf1(31 downto 16);
--	when "02" =>
--		vgadata<=buf1(15 downto 0);
--		buf1<=buf2;
--		fetchptr<=fetchptr+4;
--		sdr_req<='1';
--end case;
--
--Alternatively, could use a multiplier to shift the data - might use fewer LEs?
--
--In the meantime, we will constantly fetch data from SDRAM, and feed it into buf3.
--As soon as buf3 is filled, we move the contents into buf2, and drop the req signal.
--


entity vga_controller is
  port (
		clk : in std_logic;
		reset : in std_logic;

		reg_addr_in : in std_logic_vector(11 downto 0); -- from host CPU
		reg_data_in: in std_logic_vector(15 downto 0);
		reg_data_out: out std_logic_vector(15 downto 0);
		reg_rw : in std_logic;
		reg_uds : in std_logic;
		reg_lds : in std_logic;
		-- FIXME - will need some kind of DTACK here for word accesses to char RAM.

		sdr_addrout : buffer std_logic_vector(23 downto 0); -- to SDRAM
		sdr_datain : in std_logic_vector(15 downto 0);	-- from SDRAM
		sdr_fill : in std_logic; -- High when data is being written from SDRAM controller
		sdr_req : buffer std_logic; -- Request service from SDRAM controller
		sdr_refresh : out std_logic;

		hsync : out std_logic; -- to monitor
		vsync : buffer std_logic; -- to monitor
		vblank_int : out std_logic; -- to interrupt controller
		red : out unsigned(3 downto 0);		-- 16-bit 5-6-5 output
		green : out unsigned(3 downto 0);
		blue : out unsigned(3 downto 0)
	);
end entity;
	
architecture rtl of vga_controller is
	signal framebuffer_pointer : std_logic_vector(23 downto 0) := X"100000";
	signal hsize : unsigned(11 downto 0) := TO_UNSIGNED(640,12);
	signal htotal : unsigned(11 downto 0) := TO_UNSIGNED(800,12);
	signal hbstart : unsigned(11 downto 0) := TO_UNSIGNED(656,12);
	signal hbstop : unsigned(11 downto 0) := TO_UNSIGNED(752,12);
	signal vsize : unsigned(11 downto 0) := TO_UNSIGNED(480,12);
	signal vtotal : unsigned(11 downto 0) := TO_UNSIGNED(525,12);
	signal vbstart : unsigned(11 downto 0) := TO_UNSIGNED(500,12);
	signal vbstop : unsigned(11 downto 0) := TO_UNSIGNED(502,12);

	signal currentX : unsigned(11 downto 0);
	signal currentY : unsigned(11 downto 0);
	signal end_of_pixel : std_logic;
	signal vga_newframe : std_logic;
	signal vgacache_req : std_logic;
	signal vgadata : std_logic_vector(15 downto 0);
	signal oddframe : std_logic;	-- Toggled each frame, used for dithering

	signal ored : unsigned(5 downto 0);
	signal ogreen : unsigned(5 downto 0);
	signal oblue : unsigned(5 downto 0);
	signal dither : unsigned(5 downto 0);
	signal chargen_window : std_logic := '0';
	signal chargen_pixel : std_logic := '0';
	
begin

	red <= ored(5 downto 2);
	green <= ogreen(5 downto 2);
	blue <= oblue(5 downto 2);

	myVgaMaster : entity work.video_vga_master
		generic map (
			clkDivBits => 4
		)
		port map (
			clk => clk,
			clkDiv => X"3",	-- 100 Mhz / (3+1) = 25 Mhz

			hSync => hsync,
			vSync => vsync,

			endOfPixel => end_of_pixel,
			endOfLine => open,
			endOfFrame => open,
			currentX => currentX,
			currentY => currentY,

			-- Setup 640x480@60hz needs ~25 Mhz
			hSyncPol => '0',
			vSyncPol => '0',
			xSize => htotal,
			ySize => vtotal,
			xSyncFr => hbstart,
			xSyncTo => hbstop,
			ySyncFr => vbstart, -- Sync pulse 2
			ySyncTo => vbstop
		);		

	myvgacache : entity work.vgacache
		port map(
			clk => clk,
			reset => reset,

			reqin => vgacache_req,
			data_out => vgadata,
			setaddr => vga_newframe,
			addrin => framebuffer_pointer,
			addrout => sdr_addrout,
			data_in => sdr_datain,
			fill => sdr_fill,
			req => sdr_req
		);

	mychargen : entity work.charactergenerator
		generic map (
			xstart => 16,
			xstop => 626,
			ystart => 256,
			ystop => 464,
			border => 7
		)
		port map (
			clk => clk,
			reset => reset,
			xpos => currentX(9 downto 0),
			ypos => currentY(9 downto 0),
			pixel_clock => end_of_pixel,
			pixel => chargen_pixel,
			window => chargen_window
		);

	process(clk,reset)	-- Hardware registers
	begin
		if reset='0' then
			reg_data_out<=X"0000";
		elsif rising_edge(clk) then
			case reg_addr_in is
				when X"000" =>
					reg_data_out<=X"00"&framebuffer_pointer(23 downto 16);
					if reg_rw='0' and reg_uds='0' and reg_lds='0' then
						framebuffer_pointer(23 downto 16) <= reg_data_in(7 downto 0);
					end if;
				when X"002" =>
					reg_data_out<=framebuffer_pointer(15 downto 0);
					if reg_rw='0' and reg_uds='0' and reg_lds='0' then
						framebuffer_pointer(15 downto 0) <= reg_data_in;
					end if;
				when others =>
					reg_data_out<=X"0000";
			end case;
--		TODO:
--     4   Even row modulo
--     6   Odd row modulo (allows scandoubling)

--     8  HTotal
--     A  HSize (typically 640)
--     C  HBStart
--     E  HBStop

--    10  VTotal
--    12  VSize (typically 480)
--    14  VBStart
--    16  VBStop

--    18  Control:
--     0  Visible
--     1  Resolution - high, low  - alternatively could make pixel clock programmable...
--     7  Character overlay on/off
		end if;
	end process;
	
	process(clk, reset,currentX, currentY)
	begin
		if rising_edge(clk) then
			sdr_refresh <='0';
			if end_of_pixel='1' and currentX=hsize then
				sdr_refresh<='1';
			end if;
		end if;
		
		if reset='0' then
			htotal <= TO_UNSIGNED(800,12);
			vtotal <= TO_UNSIGNED(525,12);
			hbstart <= TO_UNSIGNED(656,12);
			hbstop <= TO_UNSIGNED(752,12);
			vbstart <= TO_UNSIGNED(500,12);
			vbstop <= TO_UNSIGNED(502,12);
			vgacache_req <='0';
		elsif rising_edge(clk) then
			vgacache_req<='0';
			vga_newframe<='0';
			vgacache_req<='0';
			vblank_int<='0';
			if end_of_pixel='1' then

			-- Dither: bit 1: temporal dithering, alternate lines swapped each frame
				--         bit 0: spatial dithering, alternate pixels
				dither<="0000" & (currentX(0) xor currentY(0)) & (currentY(0) xor oddframe);

				if currentX<640 and currentY<480 then
					-- Request next pixel from VGA cache
					vgacache_req<='1';

					-- Now dither the pixel.  If we're drawing a pixel from the character
					-- generator, or the pixel is already at max, we just draw max to avoid overflow.
					if chargen_pixel='1' or (chargen_window='0' and vgadata(15 downto 12)="1111") then
						ored <= "111111";
					elsif chargen_window='1' then
						ored <= unsigned('0'&vgadata(15 downto 11)) + dither;
					else
						ored <= unsigned(vgadata(15 downto 11)&'0') + dither;
					end if;

					if chargen_pixel='1' or (chargen_window='0' and vgadata(10 downto 7)="1111") then
						ogreen <= "111111";
					elsif chargen_window='1' then
						ogreen <= unsigned('0'&vgadata(10 downto 6)) + dither;
					else
						ogreen <= unsigned(vgadata(10 downto 5)) + dither;
					end if;

					if chargen_pixel='1' or (chargen_window='0' and vgadata(4 downto 1)="1111") then
						oblue <= "111111";
					elsif chargen_window='1' then
						oblue <= unsigned('0'&vgadata(4 downto 0)) + dither;
					else
						oblue <= unsigned(vgadata(4 downto 0)&'0') + dither;
					end if;

				else
					ored<="000000"; -- need to set black during sync periods.
					ogreen<="000000";
					oblue<="000000";
					if currentY=vsize and currentX=0 then
						oddframe<=not oddframe;
						vblank_int<='1';
					elsif currentY=(vtotal and X"ff8") and currentX=0 then
						vga_newframe<='1'; -- FIXME - replace with address loading logic.
					end if;
				end if;
			end if;
		end if;
	end process;
		
end architecture;