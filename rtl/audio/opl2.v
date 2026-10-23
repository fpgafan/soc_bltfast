// ============================================================================
// opl2.v - FM synthesizer compatible with the OPL2 (YM3812 / AdLib)
//
//  9 two-operator channels, waveforms 0-3 (with WSE), vibrato and tremolo,
//  KSL/KSR, feedback, NTS and DAM/DVB. Bit-exact with Nuked-OPL3
//  in OPL2 mode (reference model: sim/oplmodel.py). No rhythm mode
//  (bit 5 of 0xBD) and no timers.
//  Algorithm and tables from Nuked-OPL3 (nukeykt): LGPL 2.1, see LICENSE.nuked-opl3.
//  Computes the 18 operators one after another (~22 cycles each) on every
//  'tick' (~49716 Hz, the original chip's rate: 3.58 MHz / 72).
//
//  Registers (base 0x8000_9000):
//    +0x000..0x3FC  W  OPL register n at +n*4 (like ports 0x388/0x389)
//    +0x400         RW [7:0] output gain (0x40 = 1.0, default 0x80)
//    +0x404         R  samples generated
// ============================================================================
`default_nettype none
module opl2 (
    input  wire        clk,
    input  wire        rst,
    input  wire        sel,
    input  wire        we,
    input  wire [10:0] a,
    input  wire [31:0] wd,
    output reg  [31:0] rd,
    input  wire        tick,
    output reg  signed [15:0] smp,
    output reg         smp_valid
);
    // =====================================================================
    // OPL registers: 256-byte RAM (CPU writes, engine reads)
    // =====================================================================
    reg  [7:0] regs [0:255];
    reg  [7:0] ra, rq;
    wire       wr_reg = sel && we && !a[10];
    reg        clr;                        // clear after reset
    reg  [7:0] clr_a;
    always @(posedge clk) begin
        if (clr) regs[clr_a] <= 8'd0;
        else if (wr_reg) regs[a[9:2]] <= wd[7:0];
        rq <= regs[ra];
    end
    // copies of the global registers
    reg wse, nts, dam, dvb;
    reg [7:0]  gain;
    reg [31:0] count;
    always @(posedge clk) begin
        if (rst || clr) begin
            wse <= 1'b0; nts <= 1'b0; dam <= 1'b0; dvb <= 1'b0;
        end else if (wr_reg) begin
            if (a[9:2] == 8'h01) wse <= wd[5];
            if (a[9:2] == 8'h08) nts <= wd[6];
            if (a[9:2] == 8'hBD) begin dam <= wd[7]; dvb <= wd[6]; end
        end
        if (rst) gain <= 8'h80;
        else if (sel && we && a[10] && a[3:2] == 2'd0) gain <= wd[7:0];
        rd <= !a[10] ? 32'd0 : a[3:2] == 2'd0 ? {24'd0, gain} : a[3:2] == 2'd1 ? count : 32'd0;
    end

    // =====================================================================
    // State of the 18 operators
    // =====================================================================
    reg        [18:0] st_ph    [0:31];
    reg        [8:0]  st_rout  [0:31];
    reg        [1:0]  st_gen   [0:31];
    reg signed [12:0] st_out   [0:31];
    reg signed [12:0] st_prout [0:31];

    // =====================================================================
    // Tables
    // =====================================================================
    function [11:0] logsin(input [7:0] i);
        case (i)
        8'd0: logsin = 12'h859; 8'd1: logsin = 12'h6c3; 8'd2: logsin = 12'h607; 8'd3: logsin = 12'h58b;
        8'd4: logsin = 12'h52e; 8'd5: logsin = 12'h4e4; 8'd6: logsin = 12'h4a6; 8'd7: logsin = 12'h471;
        8'd8: logsin = 12'h443; 8'd9: logsin = 12'h41a; 8'd10: logsin = 12'h3f5; 8'd11: logsin = 12'h3d3;
        8'd12: logsin = 12'h3b5; 8'd13: logsin = 12'h398; 8'd14: logsin = 12'h37e; 8'd15: logsin = 12'h365;
        8'd16: logsin = 12'h34e; 8'd17: logsin = 12'h339; 8'd18: logsin = 12'h324; 8'd19: logsin = 12'h311;
        8'd20: logsin = 12'h2ff; 8'd21: logsin = 12'h2ed; 8'd22: logsin = 12'h2dc; 8'd23: logsin = 12'h2cd;
        8'd24: logsin = 12'h2bd; 8'd25: logsin = 12'h2af; 8'd26: logsin = 12'h2a0; 8'd27: logsin = 12'h293;
        8'd28: logsin = 12'h286; 8'd29: logsin = 12'h279; 8'd30: logsin = 12'h26d; 8'd31: logsin = 12'h261;
        8'd32: logsin = 12'h256; 8'd33: logsin = 12'h24b; 8'd34: logsin = 12'h240; 8'd35: logsin = 12'h236;
        8'd36: logsin = 12'h22c; 8'd37: logsin = 12'h222; 8'd38: logsin = 12'h218; 8'd39: logsin = 12'h20f;
        8'd40: logsin = 12'h206; 8'd41: logsin = 12'h1fd; 8'd42: logsin = 12'h1f5; 8'd43: logsin = 12'h1ec;
        8'd44: logsin = 12'h1e4; 8'd45: logsin = 12'h1dc; 8'd46: logsin = 12'h1d4; 8'd47: logsin = 12'h1cd;
        8'd48: logsin = 12'h1c5; 8'd49: logsin = 12'h1be; 8'd50: logsin = 12'h1b7; 8'd51: logsin = 12'h1b0;
        8'd52: logsin = 12'h1a9; 8'd53: logsin = 12'h1a2; 8'd54: logsin = 12'h19b; 8'd55: logsin = 12'h195;
        8'd56: logsin = 12'h18f; 8'd57: logsin = 12'h188; 8'd58: logsin = 12'h182; 8'd59: logsin = 12'h17c;
        8'd60: logsin = 12'h177; 8'd61: logsin = 12'h171; 8'd62: logsin = 12'h16b; 8'd63: logsin = 12'h166;
        8'd64: logsin = 12'h160; 8'd65: logsin = 12'h15b; 8'd66: logsin = 12'h155; 8'd67: logsin = 12'h150;
        8'd68: logsin = 12'h14b; 8'd69: logsin = 12'h146; 8'd70: logsin = 12'h141; 8'd71: logsin = 12'h13c;
        8'd72: logsin = 12'h137; 8'd73: logsin = 12'h133; 8'd74: logsin = 12'h12e; 8'd75: logsin = 12'h129;
        8'd76: logsin = 12'h125; 8'd77: logsin = 12'h121; 8'd78: logsin = 12'h11c; 8'd79: logsin = 12'h118;
        8'd80: logsin = 12'h114; 8'd81: logsin = 12'h10f; 8'd82: logsin = 12'h10b; 8'd83: logsin = 12'h107;
        8'd84: logsin = 12'h103; 8'd85: logsin = 12'h0ff; 8'd86: logsin = 12'h0fb; 8'd87: logsin = 12'h0f8;
        8'd88: logsin = 12'h0f4; 8'd89: logsin = 12'h0f0; 8'd90: logsin = 12'h0ec; 8'd91: logsin = 12'h0e9;
        8'd92: logsin = 12'h0e5; 8'd93: logsin = 12'h0e2; 8'd94: logsin = 12'h0de; 8'd95: logsin = 12'h0db;
        8'd96: logsin = 12'h0d7; 8'd97: logsin = 12'h0d4; 8'd98: logsin = 12'h0d1; 8'd99: logsin = 12'h0cd;
        8'd100: logsin = 12'h0ca; 8'd101: logsin = 12'h0c7; 8'd102: logsin = 12'h0c4; 8'd103: logsin = 12'h0c1;
        8'd104: logsin = 12'h0be; 8'd105: logsin = 12'h0bb; 8'd106: logsin = 12'h0b8; 8'd107: logsin = 12'h0b5;
        8'd108: logsin = 12'h0b2; 8'd109: logsin = 12'h0af; 8'd110: logsin = 12'h0ac; 8'd111: logsin = 12'h0a9;
        8'd112: logsin = 12'h0a7; 8'd113: logsin = 12'h0a4; 8'd114: logsin = 12'h0a1; 8'd115: logsin = 12'h09f;
        8'd116: logsin = 12'h09c; 8'd117: logsin = 12'h099; 8'd118: logsin = 12'h097; 8'd119: logsin = 12'h094;
        8'd120: logsin = 12'h092; 8'd121: logsin = 12'h08f; 8'd122: logsin = 12'h08d; 8'd123: logsin = 12'h08a;
        8'd124: logsin = 12'h088; 8'd125: logsin = 12'h086; 8'd126: logsin = 12'h083; 8'd127: logsin = 12'h081;
        8'd128: logsin = 12'h07f; 8'd129: logsin = 12'h07d; 8'd130: logsin = 12'h07a; 8'd131: logsin = 12'h078;
        8'd132: logsin = 12'h076; 8'd133: logsin = 12'h074; 8'd134: logsin = 12'h072; 8'd135: logsin = 12'h070;
        8'd136: logsin = 12'h06e; 8'd137: logsin = 12'h06c; 8'd138: logsin = 12'h06a; 8'd139: logsin = 12'h068;
        8'd140: logsin = 12'h066; 8'd141: logsin = 12'h064; 8'd142: logsin = 12'h062; 8'd143: logsin = 12'h060;
        8'd144: logsin = 12'h05e; 8'd145: logsin = 12'h05c; 8'd146: logsin = 12'h05b; 8'd147: logsin = 12'h059;
        8'd148: logsin = 12'h057; 8'd149: logsin = 12'h055; 8'd150: logsin = 12'h053; 8'd151: logsin = 12'h052;
        8'd152: logsin = 12'h050; 8'd153: logsin = 12'h04e; 8'd154: logsin = 12'h04d; 8'd155: logsin = 12'h04b;
        8'd156: logsin = 12'h04a; 8'd157: logsin = 12'h048; 8'd158: logsin = 12'h046; 8'd159: logsin = 12'h045;
        8'd160: logsin = 12'h043; 8'd161: logsin = 12'h042; 8'd162: logsin = 12'h040; 8'd163: logsin = 12'h03f;
        8'd164: logsin = 12'h03e; 8'd165: logsin = 12'h03c; 8'd166: logsin = 12'h03b; 8'd167: logsin = 12'h039;
        8'd168: logsin = 12'h038; 8'd169: logsin = 12'h037; 8'd170: logsin = 12'h035; 8'd171: logsin = 12'h034;
        8'd172: logsin = 12'h033; 8'd173: logsin = 12'h031; 8'd174: logsin = 12'h030; 8'd175: logsin = 12'h02f;
        8'd176: logsin = 12'h02e; 8'd177: logsin = 12'h02d; 8'd178: logsin = 12'h02b; 8'd179: logsin = 12'h02a;
        8'd180: logsin = 12'h029; 8'd181: logsin = 12'h028; 8'd182: logsin = 12'h027; 8'd183: logsin = 12'h026;
        8'd184: logsin = 12'h025; 8'd185: logsin = 12'h024; 8'd186: logsin = 12'h023; 8'd187: logsin = 12'h022;
        8'd188: logsin = 12'h021; 8'd189: logsin = 12'h020; 8'd190: logsin = 12'h01f; 8'd191: logsin = 12'h01e;
        8'd192: logsin = 12'h01d; 8'd193: logsin = 12'h01c; 8'd194: logsin = 12'h01b; 8'd195: logsin = 12'h01a;
        8'd196: logsin = 12'h019; 8'd197: logsin = 12'h018; 8'd198: logsin = 12'h017; 8'd199: logsin = 12'h017;
        8'd200: logsin = 12'h016; 8'd201: logsin = 12'h015; 8'd202: logsin = 12'h014; 8'd203: logsin = 12'h014;
        8'd204: logsin = 12'h013; 8'd205: logsin = 12'h012; 8'd206: logsin = 12'h011; 8'd207: logsin = 12'h011;
        8'd208: logsin = 12'h010; 8'd209: logsin = 12'h00f; 8'd210: logsin = 12'h00f; 8'd211: logsin = 12'h00e;
        8'd212: logsin = 12'h00d; 8'd213: logsin = 12'h00d; 8'd214: logsin = 12'h00c; 8'd215: logsin = 12'h00c;
        8'd216: logsin = 12'h00b; 8'd217: logsin = 12'h00a; 8'd218: logsin = 12'h00a; 8'd219: logsin = 12'h009;
        8'd220: logsin = 12'h009; 8'd221: logsin = 12'h008; 8'd222: logsin = 12'h008; 8'd223: logsin = 12'h007;
        8'd224: logsin = 12'h007; 8'd225: logsin = 12'h007; 8'd226: logsin = 12'h006; 8'd227: logsin = 12'h006;
        8'd228: logsin = 12'h005; 8'd229: logsin = 12'h005; 8'd230: logsin = 12'h005; 8'd231: logsin = 12'h004;
        8'd232: logsin = 12'h004; 8'd233: logsin = 12'h004; 8'd234: logsin = 12'h003; 8'd235: logsin = 12'h003;
        8'd236: logsin = 12'h003; 8'd237: logsin = 12'h002; 8'd238: logsin = 12'h002; 8'd239: logsin = 12'h002;
        8'd240: logsin = 12'h002; 8'd241: logsin = 12'h001; 8'd242: logsin = 12'h001; 8'd243: logsin = 12'h001;
        8'd244: logsin = 12'h001; 8'd245: logsin = 12'h001; 8'd246: logsin = 12'h001; 8'd247: logsin = 12'h001;
        8'd248: logsin = 12'h000; 8'd249: logsin = 12'h000; 8'd250: logsin = 12'h000; 8'd251: logsin = 12'h000;
        8'd252: logsin = 12'h000; 8'd253: logsin = 12'h000; 8'd254: logsin = 12'h000; 8'd255: logsin = 12'h000;
        default: logsin = 12'h0;
        endcase
    endfunction
    function [10:0] expt(input [7:0] i);
        case (i)
        8'd0: expt = 11'h7fa; 8'd1: expt = 11'h7f5; 8'd2: expt = 11'h7ef; 8'd3: expt = 11'h7ea;
        8'd4: expt = 11'h7e4; 8'd5: expt = 11'h7df; 8'd6: expt = 11'h7da; 8'd7: expt = 11'h7d4;
        8'd8: expt = 11'h7cf; 8'd9: expt = 11'h7c9; 8'd10: expt = 11'h7c4; 8'd11: expt = 11'h7bf;
        8'd12: expt = 11'h7b9; 8'd13: expt = 11'h7b4; 8'd14: expt = 11'h7ae; 8'd15: expt = 11'h7a9;
        8'd16: expt = 11'h7a4; 8'd17: expt = 11'h79f; 8'd18: expt = 11'h799; 8'd19: expt = 11'h794;
        8'd20: expt = 11'h78f; 8'd21: expt = 11'h78a; 8'd22: expt = 11'h784; 8'd23: expt = 11'h77f;
        8'd24: expt = 11'h77a; 8'd25: expt = 11'h775; 8'd26: expt = 11'h770; 8'd27: expt = 11'h76a;
        8'd28: expt = 11'h765; 8'd29: expt = 11'h760; 8'd30: expt = 11'h75b; 8'd31: expt = 11'h756;
        8'd32: expt = 11'h751; 8'd33: expt = 11'h74c; 8'd34: expt = 11'h747; 8'd35: expt = 11'h742;
        8'd36: expt = 11'h73d; 8'd37: expt = 11'h738; 8'd38: expt = 11'h733; 8'd39: expt = 11'h72e;
        8'd40: expt = 11'h729; 8'd41: expt = 11'h724; 8'd42: expt = 11'h71f; 8'd43: expt = 11'h71a;
        8'd44: expt = 11'h715; 8'd45: expt = 11'h710; 8'd46: expt = 11'h70b; 8'd47: expt = 11'h706;
        8'd48: expt = 11'h702; 8'd49: expt = 11'h6fd; 8'd50: expt = 11'h6f8; 8'd51: expt = 11'h6f3;
        8'd52: expt = 11'h6ee; 8'd53: expt = 11'h6e9; 8'd54: expt = 11'h6e5; 8'd55: expt = 11'h6e0;
        8'd56: expt = 11'h6db; 8'd57: expt = 11'h6d6; 8'd58: expt = 11'h6d2; 8'd59: expt = 11'h6cd;
        8'd60: expt = 11'h6c8; 8'd61: expt = 11'h6c4; 8'd62: expt = 11'h6bf; 8'd63: expt = 11'h6ba;
        8'd64: expt = 11'h6b5; 8'd65: expt = 11'h6b1; 8'd66: expt = 11'h6ac; 8'd67: expt = 11'h6a8;
        8'd68: expt = 11'h6a3; 8'd69: expt = 11'h69e; 8'd70: expt = 11'h69a; 8'd71: expt = 11'h695;
        8'd72: expt = 11'h691; 8'd73: expt = 11'h68c; 8'd74: expt = 11'h688; 8'd75: expt = 11'h683;
        8'd76: expt = 11'h67f; 8'd77: expt = 11'h67a; 8'd78: expt = 11'h676; 8'd79: expt = 11'h671;
        8'd80: expt = 11'h66d; 8'd81: expt = 11'h668; 8'd82: expt = 11'h664; 8'd83: expt = 11'h65f;
        8'd84: expt = 11'h65b; 8'd85: expt = 11'h657; 8'd86: expt = 11'h652; 8'd87: expt = 11'h64e;
        8'd88: expt = 11'h649; 8'd89: expt = 11'h645; 8'd90: expt = 11'h641; 8'd91: expt = 11'h63c;
        8'd92: expt = 11'h638; 8'd93: expt = 11'h634; 8'd94: expt = 11'h630; 8'd95: expt = 11'h62b;
        8'd96: expt = 11'h627; 8'd97: expt = 11'h623; 8'd98: expt = 11'h61e; 8'd99: expt = 11'h61a;
        8'd100: expt = 11'h616; 8'd101: expt = 11'h612; 8'd102: expt = 11'h60e; 8'd103: expt = 11'h609;
        8'd104: expt = 11'h605; 8'd105: expt = 11'h601; 8'd106: expt = 11'h5fd; 8'd107: expt = 11'h5f9;
        8'd108: expt = 11'h5f5; 8'd109: expt = 11'h5f0; 8'd110: expt = 11'h5ec; 8'd111: expt = 11'h5e8;
        8'd112: expt = 11'h5e4; 8'd113: expt = 11'h5e0; 8'd114: expt = 11'h5dc; 8'd115: expt = 11'h5d8;
        8'd116: expt = 11'h5d4; 8'd117: expt = 11'h5d0; 8'd118: expt = 11'h5cc; 8'd119: expt = 11'h5c8;
        8'd120: expt = 11'h5c4; 8'd121: expt = 11'h5c0; 8'd122: expt = 11'h5bc; 8'd123: expt = 11'h5b8;
        8'd124: expt = 11'h5b4; 8'd125: expt = 11'h5b0; 8'd126: expt = 11'h5ac; 8'd127: expt = 11'h5a8;
        8'd128: expt = 11'h5a4; 8'd129: expt = 11'h5a0; 8'd130: expt = 11'h59c; 8'd131: expt = 11'h599;
        8'd132: expt = 11'h595; 8'd133: expt = 11'h591; 8'd134: expt = 11'h58d; 8'd135: expt = 11'h589;
        8'd136: expt = 11'h585; 8'd137: expt = 11'h581; 8'd138: expt = 11'h57e; 8'd139: expt = 11'h57a;
        8'd140: expt = 11'h576; 8'd141: expt = 11'h572; 8'd142: expt = 11'h56f; 8'd143: expt = 11'h56b;
        8'd144: expt = 11'h567; 8'd145: expt = 11'h563; 8'd146: expt = 11'h560; 8'd147: expt = 11'h55c;
        8'd148: expt = 11'h558; 8'd149: expt = 11'h554; 8'd150: expt = 11'h551; 8'd151: expt = 11'h54d;
        8'd152: expt = 11'h549; 8'd153: expt = 11'h546; 8'd154: expt = 11'h542; 8'd155: expt = 11'h53e;
        8'd156: expt = 11'h53b; 8'd157: expt = 11'h537; 8'd158: expt = 11'h534; 8'd159: expt = 11'h530;
        8'd160: expt = 11'h52c; 8'd161: expt = 11'h529; 8'd162: expt = 11'h525; 8'd163: expt = 11'h522;
        8'd164: expt = 11'h51e; 8'd165: expt = 11'h51b; 8'd166: expt = 11'h517; 8'd167: expt = 11'h514;
        8'd168: expt = 11'h510; 8'd169: expt = 11'h50c; 8'd170: expt = 11'h509; 8'd171: expt = 11'h506;
        8'd172: expt = 11'h502; 8'd173: expt = 11'h4ff; 8'd174: expt = 11'h4fb; 8'd175: expt = 11'h4f8;
        8'd176: expt = 11'h4f4; 8'd177: expt = 11'h4f1; 8'd178: expt = 11'h4ed; 8'd179: expt = 11'h4ea;
        8'd180: expt = 11'h4e7; 8'd181: expt = 11'h4e3; 8'd182: expt = 11'h4e0; 8'd183: expt = 11'h4dc;
        8'd184: expt = 11'h4d9; 8'd185: expt = 11'h4d6; 8'd186: expt = 11'h4d2; 8'd187: expt = 11'h4cf;
        8'd188: expt = 11'h4cc; 8'd189: expt = 11'h4c8; 8'd190: expt = 11'h4c5; 8'd191: expt = 11'h4c2;
        8'd192: expt = 11'h4be; 8'd193: expt = 11'h4bb; 8'd194: expt = 11'h4b8; 8'd195: expt = 11'h4b5;
        8'd196: expt = 11'h4b1; 8'd197: expt = 11'h4ae; 8'd198: expt = 11'h4ab; 8'd199: expt = 11'h4a8;
        8'd200: expt = 11'h4a4; 8'd201: expt = 11'h4a1; 8'd202: expt = 11'h49e; 8'd203: expt = 11'h49b;
        8'd204: expt = 11'h498; 8'd205: expt = 11'h494; 8'd206: expt = 11'h491; 8'd207: expt = 11'h48e;
        8'd208: expt = 11'h48b; 8'd209: expt = 11'h488; 8'd210: expt = 11'h485; 8'd211: expt = 11'h482;
        8'd212: expt = 11'h47e; 8'd213: expt = 11'h47b; 8'd214: expt = 11'h478; 8'd215: expt = 11'h475;
        8'd216: expt = 11'h472; 8'd217: expt = 11'h46f; 8'd218: expt = 11'h46c; 8'd219: expt = 11'h469;
        8'd220: expt = 11'h466; 8'd221: expt = 11'h463; 8'd222: expt = 11'h460; 8'd223: expt = 11'h45d;
        8'd224: expt = 11'h45a; 8'd225: expt = 11'h457; 8'd226: expt = 11'h454; 8'd227: expt = 11'h451;
        8'd228: expt = 11'h44e; 8'd229: expt = 11'h44b; 8'd230: expt = 11'h448; 8'd231: expt = 11'h445;
        8'd232: expt = 11'h442; 8'd233: expt = 11'h43f; 8'd234: expt = 11'h43c; 8'd235: expt = 11'h439;
        8'd236: expt = 11'h436; 8'd237: expt = 11'h433; 8'd238: expt = 11'h430; 8'd239: expt = 11'h42d;
        8'd240: expt = 11'h42a; 8'd241: expt = 11'h428; 8'd242: expt = 11'h425; 8'd243: expt = 11'h422;
        8'd244: expt = 11'h41f; 8'd245: expt = 11'h41c; 8'd246: expt = 11'h419; 8'd247: expt = 11'h416;
        8'd248: expt = 11'h414; 8'd249: expt = 11'h411; 8'd250: expt = 11'h40e; 8'd251: expt = 11'h40b;
        8'd252: expt = 11'h408; 8'd253: expt = 11'h406; 8'd254: expt = 11'h403; 8'd255: expt = 11'h400;
        default: expt = 11'h0;
        endcase
    endfunction
    function [4:0] mt(input [3:0] m);
        case (m)
        4'd0: mt = 5'd1;   4'd1: mt = 5'd2;   4'd2: mt = 5'd4;   4'd3: mt = 5'd6;
        4'd4: mt = 5'd8;   4'd5: mt = 5'd10;  4'd6: mt = 5'd12;  4'd7: mt = 5'd14;
        4'd8: mt = 5'd16;  4'd9: mt = 5'd18;  4'd10: mt = 5'd20; 4'd11: mt = 5'd20;
        4'd12: mt = 5'd24; 4'd13: mt = 5'd24; default: mt = 5'd30;
        endcase
    endfunction
    function [6:0] kslrom(input [3:0] f);
        case (f)
        4'd0: kslrom = 7'd0;   4'd1: kslrom = 7'd32;  4'd2: kslrom = 7'd40;  4'd3: kslrom = 7'd45;
        4'd4: kslrom = 7'd48;  4'd5: kslrom = 7'd51;  4'd6: kslrom = 7'd53;  4'd7: kslrom = 7'd55;
        4'd8: kslrom = 7'd56;  4'd9: kslrom = 7'd58;  4'd10: kslrom = 7'd59; 4'd11: kslrom = 7'd60;
        4'd12: kslrom = 7'd61; 4'd13: kslrom = 7'd62; 4'd14: kslrom = 7'd63; default: kslrom = 7'd64;
        endcase
    endfunction

    // =====================================================================
    // Engine
    // =====================================================================
    localparam S_CLR = 5'd0, S_IDLE = 5'd1, S_RD = 5'd2, S_E1 = 5'd3, S_E2 = 5'd4,
               S_E3 = 5'd5, S_E4 = 5'd6, S_E5 = 5'd7, S_P1 = 5'd8, S_P2 = 5'd9,
               S_W1 = 5'd10, S_W2 = 5'd11, S_W3 = 5'd12, S_W4 = 5'd13, S_WB = 5'd14,
               S_F1 = 5'd15, S_F2 = 5'd16, S_F3 = 5'd17;
    reg [4:0]  st;
    reg [4:0]  s;                          // operator 0..17
    reg [3:0]  k;                          // register read
    // operator s -> register offset, channel and role (0 modulator, 1 carrier)
    wire [4:0] s_off = s + {s >= 5'd12, s >= 5'd6 && s < 5'd12, 1'b0} ;
    wire [2:0] s6    = s >= 5'd12 ? s - 5'd12 : s >= 5'd6 ? s - 5'd6 : s;   // s % 6
    wire [3:0] s_ch  = (s >= 5'd12 ? 4'd6 : s >= 5'd6 ? 4'd3 : 4'd0) + (s6 >= 3'd3 ? s6 - 3'd3 : s6);
    wire       s_op  = s6 >= 3'd3;
    always @(*) begin
        case (k)
        4'd0: ra = 8'h20 + s_off;
        4'd1: ra = 8'h40 + s_off;
        4'd2: ra = 8'h60 + s_off;
        4'd3: ra = 8'h80 + s_off;
        4'd4: ra = 8'hE0 + s_off;
        4'd5: ra = 8'hA0 + s_ch;
        4'd6: ra = 8'hB0 + s_ch;
        default: ra = 8'hC0 + s_ch;
        endcase
    end
    reg [7:0] r20, r40, r60, r80, rE0, rA0, rB0, rC0;
    wire [9:0] fnum  = {rB0[1:0], rA0};
    wire [2:0] block = rB0[4:2];
    wire       key   = rB0[5];
    wire [2:0] fb    = rC0[3:1];
    wire       con   = rC0[0];
    wire       am = r20[7], vib = r20[6], egt = r20[5], ksr = r20[4];
    wire [3:0] mult = r20[3:0];
    wire [1:0] kslv = r40[7:6];
    wire [5:0] tl   = r40[5:0];
    wire [3:0] ar = r60[7:4], dr = r60[3:0], rr = r80[3:0];
    wire [4:0] sl = (r80[7:4] == 4'hF) ? 5'h1F : {1'b0, r80[7:4]};
    wire [1:0] wf = wse ? rE0[1:0] : 2'd0;

    // current operator state
    reg        [18:0] cur_ph;
    reg        [8:0]  cur_rout;
    reg        [1:0]  cur_gen;
    reg signed [12:0] cur_out, cur_prout, modout;
    // envelope
    reg signed [9:0]  ksl_raw;
    reg        [7:0]  eg_ksl;
    reg        [3:0]  ksv, ks;
    reg               reset_eg;
    reg        [3:0]  reg_rate;
    reg        [10:0] eg_out;
    reg        [3:0]  rate_hi;
    reg        [1:0]  rate_lo;
    reg               nonzero, eg_off;
    reg        [1:0]  shift;
    reg        [8:0]  new_rout;
    reg        [1:0]  new_gen;
    // feedback
    reg signed [13:0] fbsum;
    reg signed [11:0] fbmod;
    // phase
    reg        [10:0] f_vib;
    reg        [16:0] basefreq;
    reg        [9:0]  phase_out, phsum;
    reg        [18:0] new_ph;
    // waveform
    reg               w_neg, w_max;
    reg        [11:0] ls_q;
    reg        [12:0] lvl;
    reg        [10:0] ex_q;
    reg signed [12:0] new_out;
    // mix and LFO
    reg signed [17:0] mix;
    reg signed [25:0] mixg;
    reg        [15:0] timer;
    reg        [7:0]  tpos;
    reg        [4:0]  tremolo;
    reg        [2:0]  vibpos;
    reg        [12:0] eg_timer;
    reg               eg_state;
    reg        [3:0]  eg_add;
    reg        [1:0]  eg_timer_lo;

    // stepped increment of the high rates (eg_incstep)
    function incstep(input [1:0] lo, input [1:0] t);
        case (lo)
        2'd0: incstep = 1'b0;
        2'd1: incstep = (t == 2'd0);
        2'd2: incstep = ~t[0];
        default: incstep = (t != 2'd3);
        endcase
    endfunction

    wire [6:0] rate     = {3'd0, ks} + {1'b0, reg_rate, 2'b00};
    wire [4:0] eg_shift = {1'b0, rate_hi} + {1'b0, eg_add};
    wire [2:0] sh_hi    = {1'b0, rate_hi[1:0]} + {2'd0, incstep(rate_lo, eg_timer_lo)};
    // attack increment: ~rout >> (4 - shift), signed
    wire signed [10:0] att_n   = ~{2'b00, cur_rout};
    wire signed [10:0] att_inc = att_n >>> (3'd4 - {1'b0, shift});
    // vibrato
    wire [2:0] vrng0 = fnum[9:7];
    wire [2:0] vrng1 = (vibpos[1:0] == 2'd0) ? 3'd0 : vibpos[0] ? {1'b0, vrng0[2:1]} : vrng0;
    wire [2:0] vrng  = dvb ? vrng1 : {1'b0, vrng1[2:1]};
    // waveform: index into the logsin table
    wire [7:0] ls_idx = phsum[8] ? ~phsum[7:0] : phsum[7:0];
    wire [14:0] lvl_sum = (w_max ? 15'h1000 : {3'b000, ls_q}) + {1'b0, eg_out, 3'b000};
    wire [11:0] ex_val  = {ex_q, 1'b0} >> lvl[12:8];

    integer i;
    always @(posedge clk) begin
        smp_valid <= 1'b0;
        if (rst) begin
            st <= S_CLR; clr <= 1'b1; clr_a <= 8'd0; s <= 5'd0;
            timer <= 16'd0; tpos <= 8'd0; tremolo <= 5'd0; vibpos <= 3'd0;
            eg_timer <= 13'd0; eg_state <= 1'b0; eg_add <= 4'd0; eg_timer_lo <= 2'd0;
            count <= 32'd0; smp <= 16'sd0;
        end else case (st)
        // ---------------------------------------------------------------- clear
        S_CLR: begin
            clr_a <= clr_a + 8'd1;
            if (clr_a < 8'd32) begin
                st_ph[clr_a[4:0]] <= 19'd0; st_rout[clr_a[4:0]] <= 9'h1FF; st_gen[clr_a[4:0]] <= 2'd3;
                st_out[clr_a[4:0]] <= 13'sd0; st_prout[clr_a[4:0]] <= 13'sd0;
            end
            if (clr_a == 8'd255) begin clr <= 1'b0; st <= S_IDLE; end
        end
        S_IDLE: if (tick) begin
            s <= 5'd0; k <= 4'd0; mix <= 18'sd0;
            st <= S_RD;
        end
        // ---------------------------------------------------------------- registers
        S_RD: begin
            k <= k + 4'd1;
            case (k)
            4'd1: r20 <= rq;
            4'd2: r40 <= rq;
            4'd3: r60 <= rq;
            4'd4: r80 <= rq;
            4'd5: rE0 <= rq;
            4'd6: rA0 <= rq;
            4'd7: rB0 <= rq;
            4'd8: begin rC0 <= rq; st <= S_E1; end
            default: ;
            endcase
        end
        // ---------------------------------------------------------------- envelope
        S_E1: begin
            cur_ph    <= st_ph[s];
            cur_rout  <= st_rout[s];
            cur_gen   <= st_gen[s];
            cur_out   <= st_out[s];
            cur_prout <= st_prout[s];
            modout    <= st_out[s - 5'd3];
            ksl_raw   <= $signed({1'b0, kslrom(fnum[9:6]), 2'b00}) - $signed({1'b0, 4'd8 - {1'b0, block}, 5'd0});
            ksv       <= {block, nts ? fnum[8] : fnum[9]};
            reset_eg  <= key && st_gen[s] == 2'd3;
            st <= S_E2;
        end
        S_E2: begin
            eg_ksl <= ksl_raw[9] ? 8'd0 : ksl_raw[7:0];
            if (reset_eg) reg_rate <= ar;
            else case (cur_gen)
                2'd0: reg_rate <= ar;
                2'd1: reg_rate <= dr;
                2'd2: reg_rate <= egt ? 4'd0 : rr;
                default: reg_rate <= rr;
            endcase
            ks    <= ksr ? ksv : {2'b00, ksv[3:2]};
            fbsum <= cur_prout + cur_out;
            st <= S_E3;
        end
        S_E3: begin
            eg_out  <= {2'd0, cur_rout} + {3'd0, tl, 2'b00}
                     + {3'd0, (kslv == 2'd0) ? 8'd0 : (kslv == 2'd1) ? {1'b0, eg_ksl[7:1]} :
                              (kslv == 2'd2) ? {2'b00, eg_ksl[7:2]} : eg_ksl}
                     + {6'd0, am ? tremolo : 5'd0};
            rate_hi <= rate[6] ? 4'hF : rate[5:2];
            rate_lo <= rate[1:0];
            nonzero <= reg_rate != 4'd0;
            fbmod   <= (fb == 3'd0) ? 12'sd0 : fbsum >>> (4'd9 - {1'b0, fb});
            st <= S_E4;
        end
        S_E4: begin
            if (!nonzero) shift <= 2'd0;
            else if (rate_hi < 4'd12)
                shift <= !eg_state ? 2'd0 :
                         (eg_shift == 5'd12) ? 2'd1 :
                         (eg_shift == 5'd13) ? {1'b0, rate_lo[1]} :
                         (eg_shift == 5'd14) ? {1'b0, rate_lo[0]} : 2'd0;
            else
                shift <= sh_hi[2] ? 2'd3 : (sh_hi == 3'd0) ? {1'b0, eg_state} : sh_hi[1:0];
            eg_off <= cur_rout[8:3] == 6'h3F;
            st <= S_E5;
        end
        S_E5: begin : env
            reg [8:0] lr;
            reg [8:0] inc;
            reg [1:0] g;
            lr  = cur_rout;
            inc = 9'd0;
            g   = cur_gen;
            if (reset_eg && rate_hi == 4'hF) lr = 9'd0;
            if (cur_gen != 2'd0 && !reset_eg && eg_off) lr = 9'h1FF;
            case (cur_gen)
            2'd0: if (cur_rout == 9'd0) g = 2'd1;
                  else if (key && shift != 2'd0 && rate_hi != 4'hF) inc = att_inc[8:0];
            2'd1: if (cur_rout[8:4] == sl) g = 2'd2;
                  else if (!eg_off && !reset_eg && shift != 2'd0) inc = 9'd1 << (shift - 2'd1);
            default: if (!eg_off && !reset_eg && shift != 2'd0) inc = 9'd1 << (shift - 2'd1);
            endcase
            if (reset_eg) g = 2'd0;
            if (!key) g = 2'd3;
            new_rout <= lr + inc;
            new_gen  <= g;
            // vibrato
            if (vib) f_vib <= vibpos[2] ? {1'b0, fnum} - {8'd0, vrng} : {1'b0, fnum} + {8'd0, vrng};
            else     f_vib <= {1'b0, fnum};
            st <= S_P1;
        end
        // ---------------------------------------------------------------- phase
        S_P1: begin
            basefreq  <= ({7'd0, f_vib} << block) >> 1;
            phase_out <= cur_ph[18:9];
            st <= S_P2;
        end
        S_P2: begin : ph
            reg [21:0] inc;
            reg [9:0]  m;
            inc    = ({5'd0, basefreq} * {17'd0, mt(mult)}) >> 1;
            new_ph <= (reset_eg ? 19'd0 : cur_ph) + inc[18:0];
            m = !s_op ? fbmod[9:0] : con ? 10'd0 : modout[9:0];
            phsum  <= phase_out + m;
            st <= S_W1;
        end
        // ---------------------------------------------------------------- waveform
        S_W1: begin
            case (wf)
            2'd0: begin w_neg <= phsum[9]; w_max <= 1'b0; end
            2'd1: begin w_neg <= 1'b0;     w_max <= phsum[9]; end
            2'd2: begin w_neg <= 1'b0;     w_max <= 1'b0; end
            default: begin w_neg <= 1'b0;  w_max <= phsum[8]; end
            endcase
            ls_q <= logsin(wf == 2'd3 ? phsum[7:0] : ls_idx);
            st <= S_W2;
        end
        S_W2: begin
            lvl <= (lvl_sum > 15'h1FFF) ? 13'h1FFF : lvl_sum[12:0];
            st <= S_W3;
        end
        S_W3: begin
            ex_q <= expt(lvl[7:0]);
            st <= S_W4;
        end
        S_W4: begin
            new_out <= w_neg ? ~$signed({1'b0, ex_val}) : $signed({1'b0, ex_val});
            st <= S_WB;
        end
        S_WB: begin
            st_ph[s]    <= new_ph;
            st_rout[s]  <= new_rout;
            st_gen[s]   <= new_gen;
            st_out[s]   <= new_out;
            st_prout[s] <= cur_out;
            if (s_op) mix <= mix + new_out + (con ? modout : 13'sd0);
            if (s == 5'd17) st <= S_F1;
            else begin s <= s + 5'd1; k <= 4'd0; st <= S_RD; end
        end
        // ---------------------------------------------------------------- sample and LFO
        S_F1: begin
            mixg <= mix * $signed({1'b0, gain});
            if (timer[5:0] == 6'h3F) tpos <= (tpos == 8'd209) ? 8'd0 : tpos + 8'd1;
            if (timer[9:0] == 10'h3FF) vibpos <= vibpos + 3'd1;
            timer <= timer + 16'd1;
            if (eg_state) begin
                eg_add <= eg_timer[0] ? 4'd1 : eg_timer[1] ? 4'd2 : eg_timer[2] ? 4'd3 :
                          eg_timer[3] ? 4'd4 : eg_timer[4] ? 4'd5 : eg_timer[5] ? 4'd6 :
                          eg_timer[6] ? 4'd7 : eg_timer[7] ? 4'd8 : eg_timer[8] ? 4'd9 :
                          eg_timer[9] ? 4'd10 : eg_timer[10] ? 4'd11 : eg_timer[11] ? 4'd12 :
                          eg_timer[12] ? 4'd13 : 4'd0;
                eg_timer_lo <= eg_timer[1:0];
                eg_timer <= eg_timer + 13'd1;
            end
            eg_state <= ~eg_state;
            st <= S_F2;
        end
        S_F2: begin : fin
            reg signed [25:0] x;
            reg        [7:0]  d;
            x = mixg >>> 6;
            smp <= (x > 26'sd32767) ? 16'sh7FFF : (x < -26'sd32768) ? 16'sh8000 : x[15:0];
            smp_valid <= 1'b1;
            count <= count + 32'd1;
            d = (tpos < 8'd105) ? tpos : 8'd210 - tpos;
            tremolo <= dam ? d[6:2] : {1'b0, d[7:4]};
            st <= S_IDLE;
        end
        default: st <= S_IDLE;
        endcase
    end
endmodule
`default_nettype wire
