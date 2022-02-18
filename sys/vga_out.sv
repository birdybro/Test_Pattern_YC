/* Mike Simone 
Attempt to generate a YC source for S-Video and Composite
Y	0.299R' + 0.587G' + 0.114B'
U	0.492(B' - Y) = 504 (X 1024)
V	0.877(R' - Y) = 898 (X 1024)
 C = U * Sin(wt) + V * Cos(wt) ( sin / cos generated in 2 LUTs)
YPbPr is requred in the MiSTer ini file
A AC coupling 0.1uF capacitor was used on the Chroma output, but may not be required.
This is only a concept right now and there is still a lot of work to see how well this 
can be applied to more applications or even how the existing issues can be cleaned up.
*/

module vga_out
(
	input	clk,		
	input	CLK_CHROMA,
	input	PAL_EN,

	input	ypbpr_en,

	input	hsync,
	input	vsync,
	input	csync,

	input	[23:0] din,
	output	[23:0] dout,

	output reg	hsync_o,
	output reg	vsync_o,
	output reg	csync_o
);

wire [1:0] pal = PAL_EN;
wire [7:0] red = din[23:16];
wire [7:0] green = din[15:8];
wire [7:0] blue = din[7:0];

reg [23:0] din1, din2;
reg [18:0] y_r, u_r, v_r;
reg [18:0] y_g, u_g, v_g;
reg [18:0] y_b, u_b, v_b;
reg signed [19:0] by, ry;
reg signed [19:0] u, v; 
reg signed [19:0] u_sin, v_cos, u_sin2, v_cos2;
reg signed [28:0] csin, ccos;
reg [18:0] y;
reg unsigned [7:0] Y, U, V, C, c;
reg [23:0] rgb; 
reg hsync2, vsync2, csync2;
reg hsync1, vsync1, csync1;

reg [8:0]  cburst_phase;    // colorburst counter 
reg unsigned [7:0] vref = 'd128;		// Voltage reference point (Used for Chroma)
reg [6:0]  chroma_LUT_COS = 7'd0;     // Chroma LUT counter
reg [6:0]  chroma_LUT_SIN = 7'd0;     // Chroma LUT counter
reg [6:0]  chroma_LUT = 7'd0;     // Chroma LUT counter

/*
THe following LUT tables were calculated in Google Sheets with the following
Sampling rate = 14 * 3.579545 or 50,113,560 Hz
w = =2 * PI * (3.579545*10^6)
t = 1/sampling rate
Where: 
chroma_sin_LUT = sin(wt)
chroma_cos_LUT = cos(wt)
*/

/*************************************
		7 bit Sine look up Table
**************************************/
wire signed [10:0] chroma_SIN_LUT[128] = '{
	11'h000, 11'h00C, 11'h018, 11'h025, 11'h031, 11'h03D, 11'h04A, 11'h055, 11'h061, 11'h06D, 11'h078, 
	11'h083, 11'h08D, 11'h097, 11'h0A1, 11'h0AB, 11'h0B4, 11'h0BC, 11'h0C5, 11'h0CC, 11'h0D4, 11'h0DA,
	11'h0E0, 11'h0E6, 11'h0EB, 11'h0F0, 11'h0F4, 11'h0F7, 11'h0FA, 11'h0FC, 11'h0FD, 11'h0FE, 11'h0FF, 
	11'h0FE, 11'h0FD, 11'h0FC, 11'h0FA, 11'h0F7, 11'h0F4, 11'h0F0, 11'h0EB, 11'h0E6, 11'h0E0, 11'h0DA, 
	11'h0D4, 11'h0CC, 11'h0C5, 11'h0BC, 11'h0B4, 11'h0AB, 11'h0A1, 11'h097, 11'h08D, 11'h083, 11'h078, 
	11'h06D, 11'h061, 11'h055, 11'h04A, 11'h03D, 11'h031, 11'h025, 11'h018, 11'h00C, 11'h000, 11'h7F3,
	11'h7E7, 11'h7DA, 11'h7CE, 11'h7C2, 11'h7B5, 11'h7AA, 11'h79E, 11'h792, 11'h787, 11'h77C, 11'h772,
	11'h768, 11'h75E, 11'h754, 11'h74B, 11'h743, 11'h73A, 11'h733, 11'h72B, 11'h725, 11'h71F, 11'h719, 
	11'h714, 11'h70F, 11'h70B, 11'h708, 11'h705, 11'h703, 11'h702, 11'h701, 11'h701, 11'h701, 11'h702, 
	11'h703, 11'h705, 11'h708, 11'h70B, 11'h70F, 11'h714, 11'h719, 11'h71F, 11'h725, 11'h72B, 11'h733, 
	11'h73A, 11'h743, 11'h74B, 11'h754, 11'h75E, 11'h768, 11'h772, 11'h77C, 11'h787, 11'h792, 11'h79E, 
	11'h7AA, 11'h7B5, 11'h7C2, 11'h7CE, 11'h7DA, 11'h7E7, 11'h7F3
};

/*************************************
			Phase Accumulator
**************************************/
reg [18:0] phase_accum_NTSC;
reg [18:0] phase_accum_PAL;
reg [1:0] PAL_FLIP = 1'd0;

// Phase Accumulator Increments (Fractional Size 12, look up size 7 bit, total 19 bits)
reg [18:0] NTSC_Inc = 19'd25276;
reg [18:0] PAL_Inc = 19'd31306;

always @(posedge CLK_CHROMA)   // Running at 184.5 / 2 or 74.25 Mhz 
begin
	phase_accum_NTSC <= phase_accum_NTSC + NTSC_Inc;
	phase_accum_PAL <= phase_accum_PAL + PAL_Inc;	
	chroma_LUT <= pal ? phase_accum_PAL[18:12] : phase_accum_NTSC[18:12];
end

/**************************************
	Generate Luma and Chroma Signals
***************************************/
always_ff @(posedge CLK_CHROMA) 
begin
	// Pull in sine lut value and offset 90 degrees for cos
	chroma_LUT_SIN <= chroma_LUT;
	chroma_LUT_COS <= chroma_LUT + 7'd32;

	// YUV standard for luma added
	y_r <= {red, 8'd0} + {red, 5'd0}+ {red, 4'd0} + {red, 1'd0} ;
    y_g <= {green, 9'd0} + {green, 6'd0} + {green, 4'd0} + {green, 3'd0} + green;
	y_b <= {blue, 6'd0} + {blue, 5'd0} + {blue, 4'd0} + {blue, 2'd0} + blue;
	y <= y_r + y_g + y_b;

	// Calculate for U, V - Bit Shift Multiple by u = by * 1024 x 0.492 = 504, v = ry * 1024 x 0.877 = 898
	by <= $signed($signed({12'b0 ,(blue)}) - $signed({12'b0 ,y[17:10]}));
	ry <= $signed($signed({12'b0 ,(red)}) - $signed({12'b0 ,y[17:10]}));
	u <= $signed({by, 8'd0}) +  $signed({by, 7'd0}) + $signed({by, 6'd0})  + $signed({by, 5'd0}) + $signed({by, 4'd0})  + $signed({by, 3'd0}) ; 									
	v <= $signed({ry, 9'd0}) +  $signed({ry, 8'd0}) + $signed({ry, 7'd0})  + $signed({ry, 1'd0})   ;
	
	if (hsync) 
		begin
			// Reset colorburst counter, as well as the calculated cos / sin values.
			cburst_phase <= 'd0; 	
			ccos <= 20'b0;	
			csin <= 20'b0;  
			c <= vref;
		end
	else 
		begin // Generate Colorburst for 9 cycles 
			if (cburst_phase >= 'd20 && cburst_phase <= 'd140) // Start the color burst signal at 45 samples or 0.9 us
				begin	
					// COLORBURST SIGNAL GENERATION (9 CYCLES ONLY or between count 45 - 175)
					// Set 180 degrees out of phase of sin(wt)
					csin <= -$signed({chroma_SIN_LUT[chroma_LUT_SIN],5'd0});
					ccos <= 29'b0;
					u_sin <= $signed(csin[19:0]); 

					if (pal)	// PAL routine to flip the V * COS(Wt) value every other line.
						begin
							if (PAL_FLIP)
								begin
									v_cos <= $signed(ccos[19:0]);
									PAL_FLIP <= 0;
								end 
							else 
								begin
									v_cos <= -$signed(ccos[19:0]);
									PAL_FLIP <= 1;
								end
						end
					else 
						v_cos <= $signed(ccos[19:0]);

					// Division to scale down the results to fit 8 bit.. signed numbers had to be handled a bit different. 
					// There are probably better methods here. but the standard >>> didnt work for multiple shifts.
					if (u_sin >= 0)
						begin
							u_sin2 <= u_sin[19:8]+ u_sin[19:9] ;      
						end
					else
						begin
							u_sin2 <= $signed(~(~u_sin[19:8])) + $signed(~(~u_sin[19:9]));
						end
					v_cos2 <= (v_cos>>>8);
				end
			else if (cburst_phase > 'd140) 
				begin  
					// MODULATE U, V for chroma using the SINE LUT.	
					csin <= $signed(u>>>10) * $signed(chroma_SIN_LUT[chroma_LUT_SIN]);
					ccos <= $signed(v>>>10) * $signed(chroma_SIN_LUT[chroma_LUT_COS]);

					// Turn u * sin(wt) and v * cos(wt) into signed numbers
					u_sin <= $signed(csin[19:0]);
					v_cos <= $signed(ccos[19:0]);

					// Divide U*sin(wt) and V*cos(wt) to fit results to 8 bit
					if (u_sin >= 0)
						begin
							u_sin2 <= u_sin[19:9]+ u_sin[19:10] + u_sin[19:13];       
						end
					else
						begin
							u_sin2 <= $signed(~(~u_sin[19:9])) + $signed(~(~u_sin[19:10]))+ $signed(~(~u_sin[19:13]));
						end
					if (v_cos >=0)
						begin
							v_cos2 <= v_cos[19:9] + v_cos[19:10]+ v_cos[19:13];
						end
					else
						begin
							v_cos2 <= $signed(~(~v_cos[19:9])) + $signed(~(~v_cos[19:10])) + $signed(~(~v_cos[19:13]));
						end
					end

			// Stop the colorburst timer as its only needed for the initial pulse
			if (cburst_phase <= 'd400)
				begin
					cburst_phase <= cburst_phase + 9'd1;
				end

			// Generate CHROMA 
			c <= vref + $unsigned(u_sin2[7:0]) + $unsigned(v_cos2[7:0]);
		end

	// Set Chroma output
	C <= $unsigned(c[7:0]);
	Y <= y[17:10];
	V <= v[17:10];

	hsync_o <= hsync2; hsync2 <= hsync1; hsync1 <= hsync;
	vsync_o <= vsync2; vsync2 <= vsync1; vsync1 <= vsync;
	csync_o <= csync2; csync2 <= csync1; csync1 <= csync;

	rgb <= din2; din2 <= din1; din1 <= din;
end

assign dout = ypbpr_en ? {C, Y, V} : rgb;

endmodule