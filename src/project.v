/*
 * Background Tile — scrolling tile engine for the TinyTapeout VGA Playground.
 * VGA 640x480@60Hz, 25MHz pixel clock, RGB222.
 *
 * Like the NES/SNES PPU, the screen is built from 16x16 tiles: a tilemap
 * (map128.mem, 128x30 tiles = 2048 px, loops seamlessly) holds a tile number
 * per cell, and the tileset image (mariobg256j.mem, 256x256 = 16x16 tiles)
 * holds the pixels. White tileset pixels are transparent, so SNES-style
 * background layers show through behind the tiles.
 *
 * Effects:
 *   - 4-layer parallax: tiles 1x, near hills 1/2x, far hills 1/4x, clouds 1/8x
 *   - dithered sky gradient (a per-scanline colour table, like SNES HDMA)
 *   - wave: per-scanline horizontal offset from a sine table (HDMA)
 *   - mosaic: SNES $2106-style pixel blocks, animated in and out
 *   - dithered brightness fades (SNES INIDISP) on reset and day/night switch
 *   - day/night palettes, with a sun, a crescent moon and twinkling stars
 *   - palette cycling: shimmering pond water, blinking ? blocks and coins
 *   - screen shake
 *   - sprites: two walking Goombas and spinning, bobbing coins
 *   - falling snow
 *
 * Controls (gamepad):     left/right scroll, hold B to run, start = auto-scroll
 *                         A = wave, X = mosaic, Y = day/night, select = shake,
 *                         R = snow
 * Controls (ui_in):       [0] left, [1] right, [2] wave, [3] mosaic, [7] snow
 *
 * Copyright (c) 2026 macint0
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_vga_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // Unused outputs assigned to 0.
  assign uio_out = 0;
  assign uio_oe  = 0;

  // VGA signals
  wire hsync;
  wire vsync;
  wire video_active;
  wire [9:0] pix_x;
  wire [9:0] pix_y;

  hvsync_generator vga_sync_gen (
      .clk(clk),
      .reset(~rst_n),
      .hsync(hsync),
      .vsync(vsync),
      .display_on(video_active),
      .hpos(pix_x),
      .vpos(pix_y)
  );

  // Gamepad Pmod
  wire inp_b, inp_y, inp_select, inp_start, inp_up, inp_down, inp_left, inp_right;
  wire inp_a, inp_x, inp_l, inp_r;

  gamepad_pmod_single driver (
      // Inputs:
      .rst_n(rst_n),
      .clk(clk),
      .pmod_data(ui_in[6]),
      .pmod_clk(ui_in[5]),
      .pmod_latch(ui_in[4]),
      // Outputs:
      .b(inp_b),
      .y(inp_y),
      .select(inp_select),
      .start(inp_start),
      .up(inp_up),
      .down(inp_down),
      .left(inp_left),
      .right(inp_right),
      .a(inp_a),
      .x(inp_x),
      .l(inp_l),
      .r(inp_r)
  );

  // Suppress unused signals warning
  wire _unused_ok = &{ena, uio_in, inp_up, inp_down, inp_l};

  // ---------------------------------------------------------------------
  // ROMs
  // ---------------------------------------------------------------------

  reg [5:0] tileset[0:65535];  // 256x256 px, RRGGBB
  reg [7:0] tilemap[0:4095];   // 128 columns x 32 rows (rows 30, 31 empty)
  reg [5:0] goomba[0:511];     // 32x16: two 16x16 walking frames side by side
  reg [5:0] coin[0:1023];      // 64x16: four 16x16 spin frames side by side

  initial begin
    $readmemh("../data/mariobg256j.mem", tileset);
    $readmemh("../data/map128.mem", tilemap);
    $readmemh("../data/kuribo16j.mem", goomba);
    $readmemh("../data/coinj.mem", coin);
  end

  // ---------------------------------------------------------------------
  // Per-frame state (updated once per frame, at the start of vblank)
  // ---------------------------------------------------------------------

  wire frame_tick = (pix_x == 0) && (pix_y == 480);

  reg [12:0] cam;        // camera x; tiles use cam[10:0], layers use cam >> n
  reg [9:0]  frame;
  reg        auto_on;
  reg        night;
  reg        wave_on;
  reg [4:0]  mos_t;      // mosaic animation timer, 0 = idle
  reg [4:0]  shake_t;    // screen shake timer, 0 = idle
  reg [4:0]  fade;       // brightness 0..16
  reg        fading_out;
  reg        snow_on;
  reg [10:0] gx;         // Goomba world x (the second one walks 1024 px later)
  reg        g_right;    // Goomba walking direction
  reg        prev_a, prev_x, prev_y, prev_r, prev_start, prev_select;

  wire go_left  = inp_left | ui_in[0];
  wire go_right = inp_right | ui_in[1];
  wire [12:0] run_speed = inp_b ? 13'd4 : 13'd2;

  always @(posedge clk) begin
    if (~rst_n) begin
      cam        <= 0;
      frame      <= 0;
      auto_on    <= 1;
      night      <= 0;
      wave_on    <= 0;
      mos_t      <= 0;
      shake_t    <= 0;
      fade       <= 0;
      fading_out <= 0;
      snow_on    <= 0;
      gx         <= 200;
      g_right    <= 1;
      prev_a     <= 0;
      prev_x     <= 0;
      prev_y     <= 0;
      prev_r     <= 0;
      prev_start <= 0;
      prev_select <= 0;
    end else if (frame_tick) begin
      frame <= frame + 1;

      if (go_right) cam <= cam + run_speed;
      else if (go_left) cam <= cam - run_speed;
      else if (auto_on) cam <= cam + 1;

      prev_a      <= inp_a;
      prev_x      <= inp_x;
      prev_y      <= inp_y;
      prev_r      <= inp_r;
      prev_start  <= inp_start;
      prev_select <= inp_select;

      if (inp_start & ~prev_start) auto_on <= ~auto_on;
      if (inp_a & ~prev_a) wave_on <= ~wave_on;
      if (inp_r & ~prev_r) snow_on <= ~snow_on;

      // Goomba walks 1 px every other frame, turning around at the ends
      if (frame[0]) begin
        if (g_right) begin
          if (gx == 460) g_right <= 0;
          else gx <= gx + 1;
        end else begin
          if (gx == 40) g_right <= 1;
          else gx <= gx - 1;
        end
      end

      if (inp_x & ~prev_x && mos_t == 0) mos_t <= 1;
      else if (mos_t != 0 && frame[0]) mos_t <= mos_t + 1;

      if (inp_select & ~prev_select) shake_t <= 31;
      else if (shake_t != 0) shake_t <= shake_t - 1;

      // Fade out, swap the palette while the screen is black, fade back in.
      if (inp_y & ~prev_y && !fading_out) fading_out <= 1;
      else if (fading_out) begin
        if (fade == 0) begin
          fading_out <= 0;
          night      <= ~night;
        end else fade <= fade - 1;
      end else if (fade != 16 && frame[0]) fade <= fade + 1;
    end
  end

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  // 4x4 ordered-dither threshold
  function [3:0] bayer(input [1:0] x, input [1:0] y);
    case ({y, x})
      4'h0: bayer = 0;  4'h1: bayer = 8;  4'h2: bayer = 2;  4'h3: bayer = 10;
      4'h4: bayer = 12; 4'h5: bayer = 4;  4'h6: bayer = 14; 4'h7: bayer = 6;
      4'h8: bayer = 3;  4'h9: bayer = 11; 4'hA: bayer = 1;  4'hB: bayer = 9;
      4'hC: bayer = 15; 4'hD: bayer = 7;  4'hE: bayer = 13; 4'hF: bayer = 5;
    endcase
  endfunction

  // round(7 * sin(2*pi*i/32)), two's complement
  function [10:0] wave_lut(input [4:0] i);
    case (i)
      0: wave_lut = 0;    1: wave_lut = 1;    2: wave_lut = 3;    3: wave_lut = 4;
      4: wave_lut = 5;    5: wave_lut = 6;    6: wave_lut = 6;    7: wave_lut = 7;
      8: wave_lut = 7;    9: wave_lut = 7;    10: wave_lut = 6;   11: wave_lut = 6;
      12: wave_lut = 5;   13: wave_lut = 4;   14: wave_lut = 3;   15: wave_lut = 1;
      16: wave_lut = 0;   17: wave_lut = -1;  18: wave_lut = -3;  19: wave_lut = -4;
      20: wave_lut = -5;  21: wave_lut = -6;  22: wave_lut = -6;  23: wave_lut = -7;
      24: wave_lut = -7;  25: wave_lut = -7;  26: wave_lut = -6;  27: wave_lut = -6;
      28: wave_lut = -5;  29: wave_lut = -4;  30: wave_lut = -3;  31: wave_lut = -1;
    endcase
  endfunction

  // 32x16 cloud bitmap, drawn at 2x
  function [31:0] cloud_row(input [3:0] r);
    case (r)
      0:  cloud_row = 32'b00000000000011111100000000000000;
      1:  cloud_row = 32'b00000000001111111111000000000000;
      2:  cloud_row = 32'b00000000011111111111100011100000;
      3:  cloud_row = 32'b00000011111111111111110111111000;
      4:  cloud_row = 32'b00001111111111111111111111111100;
      5:  cloud_row = 32'b00011111111111111111111111111110;
      6:  cloud_row = 32'b00111111111111111111111111111110;
      7:  cloud_row = 32'b01111111111111111111111111111111;
      8:  cloud_row = 32'b11111111111111111111111111111111;
      9:  cloud_row = 32'b11111111111111111111111111111111;
      10: cloud_row = 32'b11111111111111111111111111111111;
      11: cloud_row = 32'b01111111111111111111111111111110;
      12: cloud_row = 32'b00111111111111111111111111111100;
      13: cloud_row = 32'b00001111111111111111111111110000;
      default: cloud_row = 0;
    endcase
  endfunction

  // Sky gradient key colours, top to horizon
  function [5:0] sky_key(input n, input [1:0] i);
    case ({n, i})
      3'b000: sky_key = 6'b00_01_10;
      3'b001: sky_key = 6'b00_10_11;
      3'b010: sky_key = 6'b01_11_11;
      3'b011: sky_key = 6'b10_11_11;
      3'b100: sky_key = 6'b00_00_00;
      3'b101: sky_key = 6'b00_00_01;
      3'b110: sky_key = 6'b00_00_10;
      3'b111: sky_key = 6'b01_01_10;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Stage 0: screen-space effects -> layer coordinates
  // ---------------------------------------------------------------------

  // Mosaic block size: 1, 2, 4, 8, 16 px
  reg [2:0] mos_lvl;
  always @(*) begin
    case (mos_t[4:2])
      0: mos_lvl = (mos_t == 0) ? 3'd0 : 3'd1;
      1: mos_lvl = 2;
      2: mos_lvl = 3;
      3, 4: mos_lvl = 4;
      5: mos_lvl = 3;
      6: mos_lvl = 2;
      default: mos_lvl = 1;
    endcase
    if (ui_in[3] && mos_lvl < 3) mos_lvl = 3;
  end

  wire [3:0] mos_mask = (4'b1 << mos_lvl) - 1;
  wire [9:0] mx = pix_x & ~{6'b0, mos_mask};
  wire [9:0] my = pix_y & ~{6'b0, mos_mask};

  // Shake: jitter that dies down as the timer runs out
  wire [10:0] shake_amp = {8'b0, shake_t[4:2]};
  wire [10:0] shake_dx = frame[1] ? shake_amp : -shake_amp;
  wire [10:0] shake_dy = frame[0] ? shake_amp : -shake_amp;

  // Wave: every scanline gets its own x offset (+-14 px)
  wire        wave_en = wave_on | ui_in[2];
  wire [10:0] wave_raw = wave_lut(my[7:3] + frame[4:0]);
  wire [10:0] wave_dx = wave_en ? {wave_raw[9:0], 1'b0} : 11'd0;

  wire [10:0] sx = {1'b0, mx} + wave_dx + shake_dx;
  wire [10:0] sy_raw = {1'b0, my} + shake_dy;
  wire [8:0]  sy = sy_raw[10] ? 9'd0 : (sy_raw >= 480) ? 9'd479 : sy_raw[8:0];

  // Foreground tile layer lookup
  wire [10:0] fgx = sx + cam[10:0];
  wire [11:0] map_addr = {sy[8:4], fgx[10:4]};

  // ---------------------------------------------------------------------
  // Stage 0: background layers (back to front)
  // ---------------------------------------------------------------------

  wire [3:0] dith = bayer(sx[1:0], sy[1:0]);

  // Sky: three gradient segments of 128 lines, dithered between key colours
  wire [1:0] sky_seg = (sy >= 384) ? 2'd3 : sy[8:7];
  wire [5:0] sky_lo = sky_key(night, sky_seg);
  wire [5:0] sky_hi = sky_key(night, (sky_seg == 3) ? 2'd3 : sky_seg + 2'd1);
  wire [5:0] sky_c = (sy[6:3] > dith) ? sky_hi : sky_lo;

  // Stars (night only), fixed far away at 1/16 speed, twinkling
  wire [10:0] stx = sx + {4'b0, cam[12:4]};
  wire [7:0]  star_h = ({stx[9:3], 1'b0} ^ {sy[8:3], 2'b0}) * 8'd97 + sy[8:3];
  wire        star = night && sy < 320 && star_h[7:4] == 0 &&
                     stx[2:0] == star_h[2:0] && sy[2:0] == star_h[3:1];
  wire [5:0]  star_c = (frame[5:3] == star_h[2:0]) ? 6'b01_01_10 : 6'b11_11_11;

  // Sun / crescent moon, fixed on screen (infinitely far)
  wire [10:0] sun_dx = sx - 11'd100;
  wire [9:0]  sun_dy = {1'b0, sy} - 10'd110;
  wire        sun_box = (sun_dx[10:5] == 0 || sun_dx[10:5] == 6'h3F) &&
                        (sun_dy[9:5] == 0 || sun_dy[9:5] == 5'h1F);
  wire [5:0]  sdx = sun_dx[5:0], sdy = sun_dy[5:0];
  wire [5:0]  adx = sdx[5] ? -sdx : sdx;
  wire [5:0]  ady = sdy[5] ? -sdy : sdy;
  wire [11:0] sun_d2 = adx * adx + ady * ady;
  wire [5:0]  mdx = sdx - 6'd9, mdy = sdy + 6'd6;
  wire [5:0]  amdx = mdx[5] ? -mdx : mdx;
  wire [5:0]  amdy = mdy[5] ? -mdy : mdy;
  wire [11:0] moon_d2 = amdx * amdx + amdy * amdy;
  wire        sun = !night && sun_box && sun_d2 < 484;
  wire        halo = !night && sun_box && sun_d2 < 900 && dith < 5;
  wire        moon = night && sun_box && sun_d2 < 400 && moon_d2 >= 360;

  // Clouds: two bands drifting at different speeds
  wire [10:0] c1x = sx + {3'b0, cam[12:5]} + {3'b0, frame[9:2]};
  wire [10:0] c2x = sx + {3'b0, cam[12:4]} + {4'b0, frame[9:3]} + 11'd150;
  wire [8:0]  c1y = sy - 9'd48;
  wire [8:0]  c2y = sy - 9'd150;
  wire [31:0] c1row = cloud_row(c1y[4:1]);
  wire [31:0] c2row = cloud_row(c2y[4:1]);
  wire        cloud1 = c1y < 32 && c1x[7:6] == 0 && c1row[~c1x[5:1]];
  wire        cloud2 = c2y < 32 && c2x[7:6] == 1 && c2row[~c2x[5:1]];
  wire        cloud_shade = cloud1 ? c1y[4:1] >= 11 : c2y[4:1] >= 11;
  wire [5:0]  cloud_c = night ? (cloud_shade ? 6'b00_00_10 : 6'b01_01_10)
                              : (cloud_shade ? 6'b10_10_11 : 6'b11_11_11);

  // Far hills (1/4 speed): two triangle waves added together
  wire [10:0] fhx = sx + cam[12:2];
  wire [6:0]  ramp1 = fhx[7] ? ~fhx[6:0] : fhx[6:0];
  wire [5:0]  ramp2 = fhx[6] ? ~fhx[5:0] : fhx[5:0];
  wire [8:0]  far_top = 9'd336 - ramp1[6:1] - ramp2[5:1];
  wire        far_hill = sy >= far_top;
  wire [5:0]  far_c = (sy < far_top + 3) ? (night ? 6'b00_01_10 : 6'b10_11_10)
                                         : (night ? 6'b00_01_01 : 6'b01_10_01);

  // Near hills (1/2 speed): round bumps from a parabola
  wire [10:0] nhx = sx + cam[12:1];
  wire [5:0]  ramp3 = nhx[6] ? ~nhx[5:0] : nhx[5:0];
  wire [5:0]  bump = (ramp3 >= 32) ? ramp3 - 6'd32 : 6'd32 - ramp3;
  wire [11:0] bump2 = bump * bump;
  wire [8:0]  near_top = 9'd348 + {3'b0, bump2[10:5]};
  wire        near_hill = sy >= near_top;
  wire [5:0]  near_c = (sy < near_top + 4) ? (night ? 6'b00_10_01 : 6'b01_11_01)
                                           : (night ? 6'b00_01_00 : 6'b00_10_00);

  wire [5:0] bg_c = near_hill ? near_c :
                    far_hill  ? far_c :
                    (cloud1 | cloud2) ? cloud_c :
                    moon ? 6'b11_11_10 :
                    sun ? 6'b11_11_00 :
                    halo ? 6'b11_11_10 :
                    star ? star_c :
                    sky_c;

  // ---------------------------------------------------------------------
  // Stage 0: sprites and snow
  // ---------------------------------------------------------------------

  // Goombas stand on the ground (y 368..383). Each one is a 16x16 box in
  // world space, so they scroll together with the tiles.
  wire [10:0] g1_dx = fgx - gx;
  wire [10:0] g2_dx = fgx - gx - 11'd1024;
  wire [8:0]  g_dy = sy - 9'd368;
  wire        g_in_y = g_dy < 16;
  wire        g_hit = g_in_y && (g1_dx < 16 || g2_dx < 16);
  wire [3:0]  g_col = (g1_dx < 16) ? g1_dx[3:0] : g2_dx[3:0];
  wire [3:0]  g_fx = g_right ? ~g_col : g_col;          // face the way it walks
  wire [8:0]  g_addr = {g_dy[3:0], frame[3], g_fx};      // row*32 + frame*16 + col

  // Coins float at x 80..95 of every 256 px, bobbing out of sync
  wire [10:0] bob = wave_lut(frame[5:1] + {fgx[10:8], 2'b0});
  wire [8:0]  c_top = 9'd324 + bob[8:0];
  wire [8:0]  c_dy = sy - c_top;
  wire        c_hit = fgx[7:4] == 4'd5 && c_dy < 16;
  wire [9:0]  c_addr = {c_dy[3:0], frame[3:2], fgx[3:0]};  // row*64 + spin*16 + col

  // Snow: one 2x2 flake per 32x32 cell, at a spot picked by a hash of the
  // cell number. Moving the cells down every frame makes the snow fall.
  wire [10:0] snx = sx + cam[11:1] + {7'b0, frame[6:3]};
  wire [8:0]  sny = sy - frame[8:0];
  wire [8:0]  snow_h = {snx[9:5], sny[8:5]} * 9'd73 + 9'd41;
  wire        snow = (snow_on | ui_in[7]) && snx[4:1] == snow_h[3:0] &&
                     sny[4:1] == snow_h[7:4];

  // ---------------------------------------------------------------------
  // Pipeline: stage 1 = tilemap read, stage 2 = tileset read, stage 3 = out
  // ---------------------------------------------------------------------

  reg [7:0] s1_tile, s2_tile;
  reg [3:0] s1_offx, s1_offy;
  reg [5:0] s1_bg, s2_bg;
  reg [7:0] s1_sx, s1_sy, s2_sx, s2_sy;
  reg [5:0] s2_fg;
  reg [1:0] s1_px, s1_py, s2_px, s2_py;
  reg [8:0] s1_gaddr;
  reg [9:0] s1_caddr;
  reg       s1_ghit, s1_chit, s1_snow, s2_ghit, s2_chit, s2_snow;
  reg [5:0] s2_gc, s2_cc;
  reg [2:0] active_d, hsync_d, vsync_d;
  reg [5:0] rgb;

  always @(posedge clk) begin
    s1_tile <= tilemap[map_addr];
    s1_offx <= fgx[3:0];
    s1_offy <= sy[3:0];
    s1_bg   <= bg_c;
    s1_sx   <= sx[7:0];
    s1_sy   <= sy[7:0];
    s1_px   <= pix_x[1:0];
    s1_py   <= pix_y[1:0];
    s1_gaddr <= g_addr;
    s1_caddr <= c_addr;
    s1_ghit <= g_hit;
    s1_chit <= c_hit;
    s1_snow <= snow;

    s2_fg   <= tileset[{s1_tile[7:4], s1_offy, s1_tile[3:0], s1_offx}];
    s2_tile <= s1_tile;
    s2_bg   <= s1_bg;
    s2_sx   <= s1_sx;
    s2_sy   <= s1_sy;
    s2_px   <= s1_px;
    s2_py   <= s1_py;
    s2_gc   <= goomba[s1_gaddr];
    s2_cc   <= coin[s1_caddr];
    s2_ghit <= s1_ghit;
    s2_chit <= s1_chit;
    s2_snow <= s1_snow;

    active_d <= {active_d[1:0], video_active};
    hsync_d  <= {hsync_d[1:0], hsync};
    vsync_d  <= {vsync_d[1:0], vsync};
  end

  // ---------------------------------------------------------------------
  // Stage 2: palette effects, layer mix, brightness
  // ---------------------------------------------------------------------

  // Palette cycling: light diagonal ripples move across the pond water
  wire       water = s2_tile[7:4] >= 3 && s2_tile[7:4] <= 6 &&
                     s2_tile[3:0] >= 7 && s2_tile[3:0] <= 9;
  wire [3:0] ripple = s2_sx[5:2] + s2_sy[4:1] - frame[5:2];
  wire [5:0] fg_water = (water && s2_fg == 6'b10_11_11 && ripple < 2) ? 6'b11_11_11 : s2_fg;

  // ? blocks and coins pulse brighter every half second
  wire       blink = (s2_tile == 8'h02 || s2_tile == 8'h07) && frame[4];
  wire [1:0] fr = s2_fg[5:4], fgn = s2_fg[3:2];
  wire [5:0] fg_blink = blink ? {fr | {1'b0, fr != 0}, fgn | {1'b0, fgn != 0}, s2_fg[1:0]}
                              : fg_water;

  // Sprites go in front of the tiles; white is transparent everywhere
  wire       g_show = s2_ghit && s2_gc != 6'b11_11_11;
  wire       c_show = s2_chit && s2_cc != 6'b11_11_11;
  wire       see_through = s2_tile == 0 || s2_fg == 6'b11_11_11;
  wire [5:0] front = g_show ? s2_gc : c_show ? s2_cc : fg_blink;

  // Night: dim red and green, keep blue
  wire [1:0] nr = front[5:4], ng = front[3:2];
  wire [5:0] front_c = night ? {nr - {1'b0, nr != 0}, ng - {1'b0, ng != 0}, front[1:0]}
                             : front;

  wire [5:0] mixed = s2_snow ? 6'b11_11_11 :
                     (g_show | c_show | !see_through) ? front_c : s2_bg;

  // Brightness: channel * fade / 16, with the remainder ordered-dithered
  wire [3:0] fdith = bayer(s2_px, s2_py);
  wire [5:0] vr = mixed[5:4] * fade;
  wire [5:0] vg = mixed[3:2] * fade;
  wire [5:0] vb = mixed[1:0] * fade;
  wire [5:0] faded = {vr[5:4] + {1'b0, vr[3:0] > fdith},
                      vg[5:4] + {1'b0, vg[3:0] > fdith},
                      vb[5:4] + {1'b0, vb[3:0] > fdith}};

  always @(posedge clk) rgb <= active_d[1] ? faded : 6'b0;

  // Tiny VGA Pmod
  assign uo_out = {hsync_d[2], rgb[0], rgb[2], rgb[4], vsync_d[2], rgb[1], rgb[3], rgb[5]};

endmodule
