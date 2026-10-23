// ============================================================================
// cpu.v - CPU subsystem: rv_core + icache + dcache + cpu_mem (ROM included)
// ============================================================================
`default_nettype none
module cpu #(
    parameter [31:0] RESET_PC = 32'h0000_0000,
    parameter ROM_AW   = 11,
    parameter ROM_FILE = "boot.hex"
)(
    input  wire        clk,
    input  wire        rst,
    // SDRAM
    output wire        m_req,
    output wire        m_we,
    output wire [22:2] m_addr,
    output wire [3:0]  m_len,
    input  wire        m_ack,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wmask,
    input  wire        m_wnext,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,
    // I/O
    output wire        io_req,
    output wire        io_we,
    output wire [31:0] io_a,
    output wire [31:0] io_wd,
    output wire [3:0]  io_ws,
    input  wire        io_ack,
    input  wire [31:0] io_rd,
    // interrupts
    input  wire        irq_ext,
    input  wire        irq_timer,
    input  wire        irq_soft,
    output wire [63:0] instret
);
    wire        ic_en, ic_hit, ic_fill_req, ic_fill_done, ic_inval_req, ic_inval_done;
    wire [31:0] ic_addr, ic_rdata, ic_fill_addr;
    wire [31:0] dc_addr, dc_rdata, dc_waddr, dc_wdata;
    wire        dc_hit;
    wire [3:0]  dc_wbe;
    wire        mreq, mreq_fence, mem_hold, io_valid, io_take, sb_push, sb_full;
    wire [31:0] mreq_addr, io_addr, io_rdata, sb_addr, sb_data;
    wire [3:0]  sb_strb;

    wire        icw_de, icw_te, dcw_de, dcw_te;
    wire [10:0] icw_didx, dcw_didx;
    wire [31:0] icw_ddata, dcw_ddata;
    wire [7:0]  icw_tidx, dcw_tidx;
    wire [11:0] icw_tdata, dcw_tdata;

    rv_core #(.RESET_PC(RESET_PC)) u_core (
        .clk(clk), .rst(rst),
        .ic_en(ic_en), .ic_addr(ic_addr), .ic_rdata(ic_rdata), .ic_hit(ic_hit),
        .ic_fill_req(ic_fill_req), .ic_fill_addr(ic_fill_addr), .ic_fill_done(ic_fill_done),
        .ic_inval_req(ic_inval_req), .ic_inval_done(ic_inval_done),
        .dc_addr(dc_addr), .dc_rdata(dc_rdata), .dc_hit(dc_hit),
        .dc_wbe(dc_wbe), .dc_waddr(dc_waddr), .dc_wdata(dc_wdata),
        .mreq(mreq), .mreq_addr(mreq_addr), .mreq_fence(mreq_fence), .mem_hold(mem_hold),
        .io_valid(io_valid), .io_addr(io_addr), .io_rdata(io_rdata), .io_take(io_take),
        .sb_push(sb_push), .sb_addr(sb_addr), .sb_data(sb_data), .sb_strb(sb_strb), .sb_full(sb_full),
        .irq_ext(irq_ext), .irq_timer(irq_timer), .irq_soft(irq_soft),
        .dbg_instret(instret)
    );

    icache #(.IDXW(8)) u_ic (
        .clk(clk), .en(ic_en), .addr(ic_addr), .rdata(ic_rdata), .hit(ic_hit),
        .dwe(icw_de), .dwidx(icw_didx), .dwdata(icw_ddata),
        .twe(icw_te), .twidx(icw_tidx), .twdata(icw_tdata)
    );

    // dcache data writes come from the store in M or from the refill
    // (never both: during a refill D is stalled and M is empty)
    dcache #(.IDXW(8)) u_dc (
        .clk(clk), .raddr(dc_addr), .rdata(dc_rdata), .hit(dc_hit),
        .wbe(dcw_de ? 4'b1111 : dc_wbe),
        .widx(dcw_de ? dcw_didx : dc_waddr[12:2]),
        .wdata(dcw_de ? dcw_ddata : dc_wdata),
        .twe(dcw_te), .twidx(dcw_tidx), .twdata(dcw_tdata)
    );

    cpu_mem #(.ROM_AW(ROM_AW), .ROM_FILE(ROM_FILE)) u_mem (
        .clk(clk), .rst(rst),
        .ic_fill_req(ic_fill_req), .ic_fill_addr(ic_fill_addr), .ic_fill_done(ic_fill_done),
        .ic_inval_req(ic_inval_req), .ic_inval_done(ic_inval_done),
        .mreq(mreq), .mreq_addr(mreq_addr), .mreq_fence(mreq_fence), .mem_hold(mem_hold),
        .io_valid(io_valid), .io_addr(io_addr), .io_rdata(io_rdata), .io_take(io_take),
        .sb_push(sb_push), .sb_addr(sb_addr), .sb_data(sb_data), .sb_strb(sb_strb), .sb_full(sb_full),
        .icw_de(icw_de), .icw_didx(icw_didx), .icw_ddata(icw_ddata),
        .icw_te(icw_te), .icw_tidx(icw_tidx), .icw_tdata(icw_tdata),
        .dcw_de(dcw_de), .dcw_didx(dcw_didx), .dcw_ddata(dcw_ddata),
        .dcw_te(dcw_te), .dcw_tidx(dcw_tidx), .dcw_tdata(dcw_tdata),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack),
        .m_wdata(m_wdata), .m_wmask(m_wmask), .m_wnext(m_wnext),
        .m_rdata(m_rdata), .m_rvalid(m_rvalid),
        .io_req(io_req), .io_we(io_we), .io_a(io_a), .io_wd(io_wd), .io_ws(io_ws),
        .io_ack(io_ack), .io_rd(io_rd)
    );
endmodule
`default_nettype wire
