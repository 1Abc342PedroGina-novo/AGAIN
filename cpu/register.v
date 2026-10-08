// Copyright (C) Pedro Emanuel 2026
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

// ============================================================================
// design.sv  —  Suite completa de registradores AMD64
// Baseado em AMD64 Architecture Programmer's Manual Vol. 1-3
// Compatível com EDA Playground (design.sv + testbench.sv)
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 1) GPRs — Banco de 16 registradores de 64 bits (RAX..R15)
//    Suporta acesso em 8/16/32/64 bits, byte-alto (AH/BH/CH/DH),
//    REX-extended registers e a regra de zero-extension de 32 bits.
//    Ref: AMD64 APM Vol.1 §3.1.2
// ============================================================================
module gpr_file_64 #(
    parameter int N = 16
) (
    input  logic                clk,
    input  logic                rst_n,
    // Port A (leitura)
    input  logic [3:0]          a_idx,
    input  logic [1:0]          a_size,       // 00=8,01=16,10=32,11=64
    input  logic                a_byte_high,
    output logic [63:0]         a_data,
    // Port B (leitura)
    input  logic [3:0]          b_idx,
    input  logic [1:0]          b_size,
    input  logic                b_byte_high,
    output logic [63:0]         b_data,
    // Port C (leitura)
    input  logic [3:0]          c_idx,
    input  logic [1:0]          c_size,
    output logic [63:0]         c_data,
    // Escrita
    input  logic                wr_en,
    input  logic [3:0]          wr_idx,
    input  logic [1:0]          wr_size,
    input  logic                wr_byte_high,
    input  logic [63:0]         wr_data,
    // RSP write detect (para interceptação de stack)
    output logic                rsp_written
);
    logic [63:0] gpr [N];

    // ------------------------------------------------------------------------
    // Leitura combinacional
    // ------------------------------------------------------------------------
    function automatic logic [63:0] rdl(
        input logic [3:0] idx,
        input logic [1:0] size,
        input logic       bhigh
    );
        logic [63:0] v;
        v = gpr[idx];
        case (size)
            2'b00: rdl = bhigh ? {56'h0, v[15:8]} : {56'h0, v[7:0]};
            2'b01: rdl = {48'h0, v[15:0]};
            2'b10: rdl = {32'h0, v[31:0]};
            2'b11: rdl = v;
        endcase
    endfunction

    assign a_data = rdl(a_idx, a_size, a_byte_high);
    assign b_data = rdl(b_idx, b_size, b_byte_high);
    assign c_data = rdl(c_idx, c_size, 1'b0);

    assign rsp_written = wr_en && (wr_idx == 4'd4) &&
                         ((wr_size == 2'b11) || (wr_size == 2'b10) ||
                          (wr_size == 2'b01) || (wr_size == 2'b00));

    // ------------------------------------------------------------------------
    // Escrita sequencial
    //   8-bit  : preserva [63:8]
    //   16-bit : preserva [63:16]
    //   32-bit : ZERO-EXTENDE [63:32]   <- comportamento x86-64
    //   64-bit : escreve tudo
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N; i++) gpr[i] <= 64'h0;
        end else if (wr_en) begin
            case (wr_size)
                2'b00: begin
                    if (wr_byte_high) gpr[wr_idx][15:8] <= wr_data[7:0];
                    else              gpr[wr_idx][7:0]  <= wr_data[7:0];
                end
                2'b01: gpr[wr_idx][15:0] <= wr_data[15:0];
                2'b10: begin
                    gpr[wr_idx][31:0]  <= wr_data[31:0];
                    gpr[wr_idx][63:32] <= 32'h0;   // zero-extension obrigatório
                end
                2'b11: gpr[wr_idx][63:0] <= wr_data[63:0];
            endcase
        end
    end
endmodule


// ============================================================================
// 2) RFLAGS — Registrador de flags de 64 bits (aplicação + sistema)
//    Ref: AMD64 APM Vol.1 §3.1.4, Vol.2 §3.1.6
// ============================================================================
module rflags_64 (
    input  logic        clk,
    input  logic        rst_n,

    // --- Controles individuais (gerados pela ULA / decodificador) ---
    input  logic        cf_set, cf_clr, cf_inv,
    input  logic        pf_set, pf_clr,
    input  logic        af_set, af_clr,
    input  logic        zf_set, zf_clr,
    input  logic        sf_set, sf_clr,
    input  logic        of_set, of_clr,
    input  logic        tf_set, tf_clr,
    input  logic        if_set, if_clr,
    input  logic        df_set, df_clr,

    // --- Flags de sistema ---
    input  logic [1:0]  iopl_wr,  input logic iopl_wr_en,
    input  logic        nt_wr,    input logic nt_wr_en,
    input  logic        rf_wr,    input logic rf_wr_en,
    input  logic        vm_wr,    input logic vm_wr_en,
    input  logic        ac_wr,    input logic ac_wr_en,
    input  logic        vif_wr,   input logic vif_wr_en,
    input  logic        vip_wr,   input logic vip_wr_en,
    input  logic        id_wr,    input logic id_wr_en,

    // --- Bulk write (POPF/POPFQ/IRET/SAHF) ---
    input  logic        bulk_wr_en,
    input  logic [1:0]  bulk_size,      // 01=16, 10=32, 11=64
    input  logic [63:0] bulk_data,
    input  logic        cpl0,           // só CPL0 pode alterar IOPL/IF/VM
    input  logic        cpl_gt_iopl,    // bloqueia IF se CPL > IOPL

    output logic [63:0] rflags
);
    logic cf, pf, af, zf, sf, tf, if_f, df, of_f;
    logic [1:0] iopl;
    logic nt, rf, vm, ac, vif, vip, id;

    // RFLAGS aggregation: bits [63:32] são RAZ; bit 1 é RA1.
    assign rflags[0]     = cf;
    assign rflags[1]     = 1'b1;
    assign rflags[2]     = pf;
    assign rflags[3]     = 1'b0;
    assign rflags[4]     = af;
    assign rflags[5]     = 1'b0;
    assign rflags[6]     = zf;
    assign rflags[7]     = sf;
    assign rflags[8]     = tf;
    assign rflags[9]     = if_f;
    assign rflags[10]    = df;
    assign rflags[11]    = of_f;
    assign rflags[12]    = iopl[0];
    assign rflags[13]    = iopl[1];
    assign rflags[14]    = nt;
    assign rflags[15]    = 1'b0;
    assign rflags[16]    = rf;
    assign rflags[17]    = vm;
    assign rflags[18]    = ac;
    assign rflags[19]    = vif;
    assign rflags[20]    = vip;
    assign rflags[21]    = id;
    assign rflags[31:22] = 10'h0;
    assign rflags[63:32] = 32'h0;   // RAZ

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset: RFLAGS = 0x0000_0000_0000_0002
            cf<=0; pf<=0; af<=0; zf<=0; sf<=0; tf<=0; if_f<=0; df<=0; of_f<=0;
            iopl<=2'b00; nt<=0; rf<=0; vm<=0; ac<=0; vif<=0; vip<=0; id<=0;
        end else begin
            // ---------- Flags aritméticos ----------
            if (cf_set) cf<=1'b1;
            if (cf_clr) cf<=1'b0;
            if (cf_inv) cf<=~cf;
            if (pf_set) pf<=1'b1;
            if (pf_clr) pf<=1'b0;
            if (af_set) af<=1'b1;
            if (af_clr) af<=1'b0;
            if (zf_set) zf<=1'b1;
            if (zf_clr) zf<=1'b0;
            if (sf_set) sf<=1'b1;
            if (sf_clr) sf<=1'b0;
            if (of_set) of_f<=1'b1;
            if (of_clr) of_f<=1'b0;

            // ---------- Flags de controle ----------
            if (tf_set) tf<=1'b1;
            if (tf_clr) tf<=1'b0;
            if (if_set && (cpl0 || !cpl_gt_iopl)) if_f<=1'b1;
            if (if_clr && (cpl0 || !cpl_gt_iopl)) if_f<=1'b0;
            if (df_set) df<=1'b1;
            if (df_clr) df<=1'b0;

            // ---------- Flags de sistema ----------
            if (iopl_wr_en && cpl0) iopl <= iopl_wr;
            if (nt_wr_en)  nt  <= nt_wr;
            if (rf_wr_en)  rf  <= rf_wr;
            if (vm_wr_en && cpl0) vm <= vm_wr;
            if (ac_wr_en)  ac  <= ac_wr;
            if (vif_wr_en) vif <= vif_wr;
            if (vip_wr_en) vip <= vip_wr;
            if (id_wr_en)  id  <= id_wr;

            // ---------- Bulk write (POPF/POPFQ/IRET) ----------
            if (bulk_wr_en) begin
                // Bits baixos sempre escritos
                cf   <= bulk_data[0];
                pf   <= bulk_data[2];
                af   <= bulk_data[4];
                zf   <= bulk_data[6];
                sf   <= bulk_data[7];
                tf   <= bulk_data[8];
                df   <= bulk_data[10];
                of_f <= bulk_data[11];
                // IF: protegido por CPL
                if (cpl0 || !cpl_gt_iopl) if_f <= bulk_data[9];
                // IOPL: só CPL0
                if (cpl0) iopl <= bulk_data[13:12];
                // VM: só CPL0
                if (cpl0) vm <= bulk_data[17];

                if (bulk_size != 2'b01) begin  // 32 ou 64 bits
                    nt  <= bulk_data[14];
                    rf  <= bulk_data[16];
                    ac  <= bulk_data[18];
                    vif <= bulk_data[19];
                    vip <= bulk_data[20];
                    id  <= bulk_data[21];
                end
            end
        end
    end
endmodule


// ============================================================================
// 3) Registradores de segmento — CS, DS, ES, FS, GS, SS
//    Ref: AMD64 APM Vol.2 §4.5
// ============================================================================
module segment_regs (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        long_mode,

    // Escrita de CS (far transfer)
    input  logic        cs_wr_en,
    input  logic [15:0] cs_sel_i,
    input  logic [63:0] cs_base_i,
    input  logic [31:0] cs_limit_i,
    input  logic [15:0] cs_attr_i,    // bit L, D, DPL, etc.

    // DS/ES/SS
    input  logic        ds_wr_en, es_wr_en, ss_wr_en,
    input  logic [15:0] ds_sel_i, es_sel_i, ss_sel_i,
    input  logic [63:0] ds_base_i, es_base_i, ss_base_i,
    input  logic [31:0] ds_limit_i, es_limit_i, ss_limit_i,
    input  logic [15:0] ds_attr_i, es_attr_i, ss_attr_i,

    // FS/GS: base programável via WRMSR
    input  logic        fs_base_wr, gs_base_wr,
    input  logic [63:0] fs_base_i, gs_base_i,
    input  logic        fs_wr_en, gs_wr_en,
    input  logic [15:0] fs_sel_i, gs_sel_i,

    output logic [63:0] cs_base_o, ds_base_o, es_base_o,
                        fs_base_o, gs_base_o, ss_base_o,
    output logic [31:0] cs_limit_o, ss_limit_o,
    output logic [1:0]  cs_dpl_o,
    output logic        cs_l_o, cs_d_o, cs_p_o,
    output logic        ds_p_o, es_p_o, fs_p_o, gs_p_o, ss_p_o
);
    // CS
    logic [15:0] cs_sel; logic [63:0] cs_base; logic [31:0] cs_limit; logic [15:0] cs_attr;
    // DS
    logic [15:0] ds_sel; logic [63:0] ds_base; logic [31:0] ds_limit; logic [15:0] ds_attr;
    // ES
    logic [15:0] es_sel; logic [63:0] es_base; logic [31:0] es_limit; logic [15:0] es_attr;
    // FS
    logic [15:0] fs_sel; logic [63:0] fs_base; logic [31:0] fs_limit; logic [15:0] fs_attr;
    // GS
    logic [15:0] gs_sel; logic [63:0] gs_base; logic [31:0] gs_limit; logic [15:0] gs_attr;
    // SS
    logic [15:0] ss_sel; logic [63:0] ss_base; logic [31:0] ss_limit; logic [15:0] ss_attr;

    // Atributos: bit layout (long-mode descriptor)
    //   [15]    G
    //   [14]    D/B
    //   [13]    L
    //   [12]    AVL
    //   [11:8]  limit[19:16]
    //   [7]     P
    //   [6:5]   DPL
    //   [4]     S
    //   [3:0]   type
    assign cs_dpl_o = cs_attr[6:5];
    assign cs_l_o   = cs_attr[13];
    assign cs_d_o   = cs_attr[14];
    assign cs_p_o   = cs_attr[7];
    assign ds_p_o   = ds_attr[7];
    assign es_p_o   = es_attr[7];
    assign fs_p_o   = fs_attr[7];
    assign gs_p_o   = gs_attr[7];
    assign ss_p_o   = ss_attr[7];

    assign cs_base_o = cs_base;
    assign ds_base_o = long_mode ? 64'h0 : ds_base;
    assign es_base_o = long_mode ? 64'h0 : es_base;
    assign ss_base_o = long_mode ? 64'h0 : ss_base;
    assign fs_base_o = fs_base;
    assign gs_base_o = gs_base;
    assign cs_limit_o = cs_limit;
    assign ss_limit_o = ss_limit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset: CS = F000h com base FFFF0000h, limite FFFFh
            cs_sel <= 16'hF000; cs_base <= 64'hFFFF_0000; cs_limit <= 32'hFFFF; cs_attr <= 16'h009B;
            ds_sel <= 16'h0; ds_base <= 64'h0; ds_limit <= 32'hFFFF; ds_attr <= 16'h0093;
            es_sel <= 16'h0; es_base <= 64'h0; es_limit <= 32'hFFFF; es_attr <= 16'h0093;
            fs_sel <= 16'h0; fs_base <= 64'h0; fs_limit <= 32'hFFFF; fs_attr <= 16'h0093;
            gs_sel <= 16'h0; gs_base <= 64'h0; gs_limit <= 32'hFFFF; gs_attr <= 16'h0093;
            ss_sel <= 16'h0; ss_base <= 64'h0; ss_limit <= 32'hFFFF; ss_attr <= 16'h0093;
        end else begin
            if (cs_wr_en) begin
                cs_sel   <= cs_sel_i;
                cs_base  <= cs_base_i;
                cs_limit <= cs_limit_i;
                cs_attr  <= cs_attr_i;
            end
            if (ds_wr_en) begin
                ds_sel   <= ds_sel_i; ds_base <= ds_base_i;
                ds_limit <= ds_limit_i; ds_attr <= ds_attr_i;
            end
            if (es_wr_en) begin
                es_sel   <= es_sel_i; es_base <= es_base_i;
                es_limit <= es_limit_i; es_attr <= es_attr_i;
            end
            if (ss_wr_en) begin
                ss_sel   <= ss_sel_i; ss_base <= ss_base_i;
                ss_limit <= ss_limit_i; ss_attr <= ss_attr_i;
            end
            if (fs_wr_en) fs_sel <= fs_sel_i;
            if (gs_wr_en) gs_sel <= gs_sel_i;
            if (fs_base_wr) fs_base <= fs_base_i;
            if (gs_base_wr) gs_base <= gs_base_i;
        end
    end
endmodule


// ============================================================================
// 4) RIP — Instruction Pointer de 64 bits
//    Ref: AMD64 APM Vol.1 §2.5
// ============================================================================
module rip_64 (
    input  logic        clk, rst_n,
    input  logic        ld_en,
    input  logic [63:0] ld_val,
    input  logic [63:0] inc_val,      // incremento sequencial
    input  logic        inc_en,
    output logic [63:0] rip
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          rip <= 64'h0000_0000_0000_FFF0;
        else if (ld_en)      rip <= ld_val;
        else if (inc_en)     rip <= rip + inc_val;
    end
endmodule


// ============================================================================
// 5) AVX-512 register file — 32 registradores ZMM de 512 bits
//    Overlay: ZMM[n][511:256]=high256, [255:128]=YMM, [127:0]=XMM
//    Ref: AMD64 APM Vol.1 §4.2 + AVX-512 spec
// ============================================================================
module avx512_file #(
    parameter int NZMM = 32
) (
    input  logic                clk, rst_n,
    input  logic                long_mode,       // 1 = 64-bit mode
    input  logic                avx512_en,       // habilita ZMM16..31
    input  logic                avx_en,          // habilita YMM

    // --- Leitura ZMM (512 bits) ---
    input  logic [4:0]          rd_zmm_idx,
    output logic [511:0]        rd_zmm_data,
    // --- Leitura YMM (256 bits) ---
    input  logic [4:0]          rd_ymm_idx,
    output logic [255:0]        rd_ymm_data,
    // --- Leitura XMM (128 bits) ---
    input  logic [4:0]          rd_xmm_idx,
    output logic [127:0]        rd_xmm_data,

    // --- Escrita ZMM ---
    input  logic                wr_zmm_en,
    input  logic [4:0]          wr_zmm_idx,
    input  logic [511:0]        wr_zmm_data,
    // --- Escrita YMM (upper 256) ---
    input  logic                wr_ymm_en,
    input  logic [4:0]          wr_ymm_idx,
    input  logic [255:0]        wr_ymm_data,
    input  logic                ymm_upper_zero,  // AVX: zera upper 256
    // --- Escrita XMM (lower 128) ---
    input  logic                wr_xmm_en,
    input  logic [4:0]          wr_xmm_idx,
    input  logic [127:0]        wr_xmm_data,
    input  logic                xmm_upper_zero,  // AVX: zera upper 384
    input  logic                xmm_legacy       // legacy SSE: preserva upper
);
    logic [511:0] zmm [NZMM];

    // Acesso efetivo em non-long-mode: apenas 8 registradores
    wire [4:0] zmm_rd = (long_mode && avx512_en) ? rd_zmm_idx : {2'b0, rd_zmm_idx[2:0]};
    wire [4:0] ymm_rd = (long_mode && avx_en)    ? rd_ymm_idx : {2'b0, rd_ymm_idx[2:0]};
    wire [4:0] xmm_rd = long_mode ? rd_xmm_idx : {1'b0, rd_xmm_idx[2:0]};
    wire [4:0] zmm_wr = (long_mode && avx512_en) ? wr_zmm_idx : {2'b0, wr_zmm_idx[2:0]};
    wire [4:0] ymm_wr = (long_mode && avx_en)    ? wr_ymm_idx : {2'b0, wr_ymm_idx[2:0]};
    wire [4:0] xmm_wr = long_mode ? wr_xmm_idx : {1'b0, wr_xmm_idx[2:0]};

    assign rd_zmm_data = zmm[zmm_rd];
    assign rd_ymm_data = zmm[ymm_rd][255:0];
    assign rd_xmm_data = zmm[xmm_rd][127:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NZMM; i++) zmm[i] <= 512'h0;
        end else begin
            if (wr_zmm_en) begin
                zmm[zmm_wr] <= wr_zmm_data;
            end else if (wr_ymm_en) begin
                zmm[ymm_wr][255:0] <= wr_ymm_data;
                if (ymm_upper_zero)
                    zmm[ymm_wr][511:256] <= 256'h0;
            end else if (wr_xmm_en) begin
                zmm[xmm_wr][127:0] <= wr_xmm_data;
                if (xmm_upper_zero)
                    zmm[xmm_wr][511:128] <= 384'h0;
                else if (xmm_legacy)
                    ; // preserva bits [511:128]
            end
        end
    end
endmodule


// ============================================================================
// 6) Opmask (k0..k7) — 8 registradores de máscara AVX-512
// ============================================================================
module opmask_regs (
    input  logic        clk, rst_n,
    input  logic [2:0]  rd_idx,
    output logic [63:0] rd_data,
    input  logic        wr_en,
    input  logic [2:0]  wr_idx,
    input  logic [63:0] wr_data
);
    logic [63:0] kmask [8];
    assign rd_data = (rd_idx == 3'd0) ? 64'hFFFF_FFFF_FFFF_FFFF : kmask[rd_idx];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      for (int i = 0; i < 8; i++) kmask[i] <= 64'h0;
        else if (wr_en && wr_idx != 3'd0) kmask[wr_idx] <= wr_data;
    end
endmodule


// ============================================================================
// 7) MXCSR — Controle e status SSE (AVX-512 adiciona bits)
//    Ref: AMD64 APM Vol.1 §4.2.2
// ============================================================================
module mxcsr_reg (
    input  logic        clk, rst_n,
    input  logic        wr_en,
    input  logic [31:0] wr_data,
    output logic [31:0] mxcsr,
    // Exceções vindas da ULA SIMD
    input  logic        ie_set, de_set, ze_set, oe_set, ue_set, pe_set
);
    logic [31:0] r;
    always_comb begin
        r = mxcsr;
        if (ie_set) r[0]  = 1'b1;
        if (de_set) r[1]  = 1'b1;
        if (ze_set) r[2]  = 1'b1;
        if (oe_set) r[3]  = 1'b1;
        if (ue_set) r[4]  = 1'b1;
        if (pe_set) r[5]  = 1'b1;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)     mxcsr <= 32'h0000_1F80;   // valor de reset
        else            mxcsr <= wr_en ? wr_data : r;
    end
endmodule


// ============================================================================
// 8) Control Registers — CR0..CR8
//    Ref: AMD64 APM Vol.2 §3.1
// ============================================================================
module control_regs (
    input  logic        clk, rst_n,
    // CR0
    input  logic        cr0_wr_en,
    input  logic [63:0] cr0_i,
    output logic [63:0] cr0_o,
    // CR2 (page-fault linear address)
    input  logic        cr2_wr_en,
    input  logic [63:0] cr2_i,
    output logic [63:0] cr2_o,
    // CR3 (page tables)
    input  logic        cr3_wr_en,
    input  logic [63:0] cr3_i,
    output logic [63:0] cr3_o,
    // CR4
    input  logic        cr4_wr_en,
    input  logic [63:0] cr4_i,
    output logic [63:0] cr4_o,
    // CR8 (TPR)
    input  logic        cr8_wr_en,
    input  logic [63:0] cr8_i,
    output logic [63:0] cr8_o
);
    logic [63:0] cr0, cr2, cr3, cr4, cr8;

    assign cr0_o = cr0; assign cr2_o = cr2;
    assign cr3_o = cr3; assign cr4_o = cr4; assign cr8_o = cr8;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cr0 <= 64'h0000_0000_6000_0010;   // reset real-mode
            cr2 <= 64'h0;
            cr3 <= 64'h0;
            cr4 <= 64'h0;
            cr8 <= 64'h0;
        end else begin
            if (cr0_wr_en) cr0 <= cr0_i;
            if (cr2_wr_en) cr2 <= cr2_i;
            if (cr3_wr_en) cr3 <= cr3_i;
            if (cr4_wr_en) cr4 <= cr4_i;
            if (cr8_wr_en) cr8 <= {60'h0, cr8_i[3:0]};
        end
    end
endmodule


// ============================================================================
// 9) Debug Registers — DR0..DR7
//    Ref: AMD64 APM Vol.2 §13.1.1
// ============================================================================
module debug_regs (
    input  logic        clk, rst_n,
    // DR0-DR3 (address breakpoints)
    input  logic        dr0_wr, dr1_wr, dr2_wr, dr3_wr,
    input  logic [63:0] dr0_i, dr1_i, dr2_i, dr3_i,
    output logic [63:0] dr0_o, dr1_o, dr2_o, dr3_o,
    // DR6 status
    input  logic        dr6_wr,
    input  logic [63:0] dr6_i,
    output logic [63:0] dr6_o,
    // DR7 control
    input  logic        dr7_wr,
    input  logic [63:0] dr7_i,
    output logic [63:0] dr7_o
);
    logic [63:0] dr0, dr1, dr2, dr3, dr6, dr7;
    assign dr0_o = dr0; assign dr1_o = dr1;
    assign dr2_o = dr2; assign dr3_o = dr3;
    assign dr6_o = dr6; assign dr7_o = dr7;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dr0 <= 64'h0; dr1 <= 64'h0; dr2 <= 64'h0; dr3 <= 64'h0;
            dr6 <= 64'hFFFF_0FF0;      // reset value
            dr7 <= 64'h0000_0400;      // reset value
        end else begin
            if (dr0_wr) dr0 <= dr0_i;
            if (dr1_wr) dr1 <= dr1_i;
            if (dr2_wr) dr2 <= dr2_i;
            if (dr3_wr) dr3 <= dr3_i;
            if (dr6_wr) dr6 <= dr6_i;
            if (dr7_wr) dr7 <= dr7_i;
        end
    end
endmodule


// ============================================================================
// 10) MSR bank — registradores MSR críticos
//     EFER, STAR/LSTAR/CSTAR/SFMASK, SYSENTER_*, PAT, FS/GS base,
//     KernelGSBase, TSC_AUX
//     Ref: AMD64 APM Vol.2 §3.2
// ============================================================================
module msr_bank (
    input  logic        clk, rst_n,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [63:0] wdata,
    output logic [63:0] rdata
);
    // ------------------------------------------------------------------------
    // EFER — 0xC000_0080
    // ------------------------------------------------------------------------
    logic sce, lme, lma, nxe, svme, lmsle, ffxsr, tce;
    logic [63:0] efer;
    assign efer = {59'h0, tce, ffxsr, lmsle, svme, nxe, lma, 1'b0,
                   lme, 7'h0, sce};

    // ------------------------------------------------------------------------
    // STAR/LSTAR/CSTAR/SFMASK — 0xC000_0081..84
    // ------------------------------------------------------------------------
    logic [63:0] star, lstar, cstar, sfmask;

    // ------------------------------------------------------------------------
    // SYSENTER_* — 0x174..176
    // ------------------------------------------------------------------------
    logic [63:0] sysenter_cs, sysenter_esp, sysenter_eip;

    // ------------------------------------------------------------------------
    // PAT — 0x277
    // ------------------------------------------------------------------------
    logic [63:0] pat;

    // ------------------------------------------------------------------------
    // FS/GS base — 0xC000_0100/0101
    // ------------------------------------------------------------------------
    logic [63:0] fs_base, gs_base, kernel_gs_base;

    // ------------------------------------------------------------------------
    // TSC_AUX — 0xC000_0103
    // ------------------------------------------------------------------------
    logic [63:0] tsc_aux;

    // ------------------------------------------------------------------------
    // TSC (contador de timestamp) — 0x10
    // ------------------------------------------------------------------------
    logic [63:0] tsc;

    // ------------------------------------------------------------------------
    // Leitura
    // ------------------------------------------------------------------------
    always_comb begin
        rdata = 64'h0;
        case (addr)
            32'hC000_0080: rdata = efer;
            32'hC000_0081: rdata = star;
            32'hC000_0082: rdata = lstar;
            32'hC000_0083: rdata = cstar;
            32'hC000_0084: rdata = sfmask;
            32'h0000_0174: rdata = sysenter_cs;
            32'h0000_0175: rdata = sysenter_esp;
            32'h0000_0176: rdata = sysenter_eip;
            32'h0000_0277: rdata = pat;
            32'hC000_0100: rdata = fs_base;
            32'hC000_0101: rdata = gs_base;
            32'hC000_0102: rdata = kernel_gs_base;
            32'hC000_0103: rdata = tsc_aux;
            32'h0000_0010: rdata = tsc;
            default:       rdata = 64'h0;
        endcase
    end

    // ------------------------------------------------------------------------
    // Escrita
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {sce,lme,lma,nxe,svme,lmsle,ffxsr,tce} <= 8'h0;
            star<=0; lstar<=0; cstar<=0; sfmask<=0;
            sysenter_cs<=0; sysenter_esp<=0; sysenter_eip<=0;
            pat <= 64'h0007_0406_0007_0406;   // valor de reset
            fs_base<=0; gs_base<=0; kernel_gs_base<=0;
            tsc_aux<=0; tsc<=0;
        end else begin
            tsc <= tsc + 64'h1;   // conta sempre
            if (we) begin
                case (addr)
                    32'hC000_0080: begin
                        sce   <= wdata[0];
                        lme   <= wdata[8];
                        lma   <= wdata[10];  // hard-set pelo VMRUN, mas aceito escrita aqui
                        nxe   <= wdata[11];
                        svme  <= wdata[12];
                        lmsle <= wdata[13];
                        ffxsr <= wdata[14];
                        tce   <= wdata[15];
                    end
                    32'hC000_0081: star          <= wdata;
                    32'hC000_0082: lstar         <= wdata;
                    32'hC000_0083: cstar         <= wdata;
                    32'hC000_0084: sfmask        <= wdata;
                    32'h0000_0174: sysenter_cs   <= wdata;
                    32'h0000_0175: sysenter_esp  <= wdata;
                    32'h0000_0176: sysenter_eip  <= wdata;
                    32'h0000_0277: pat           <= wdata;
                    32'hC000_0100: fs_base       <= wdata;
                    32'hC000_0101: gs_base       <= wdata;
                    32'hC000_0102: kernel_gs_base<= wdata;
                    32'hC000_0103: tsc_aux       <= wdata;
                    32'h0000_0010: tsc           <= wdata;
                    default: ;
                endcase
            end
        end
    end

    // Saídas para outros módulos (FS/GS base, EFER.LME, etc.)
    `ifdef EXPOSE_MSR_INTERFACE
    // Pode ser estendido via interface struct
    `endif
endmodule


// ============================================================================
// 11) Local APIC — registradores MMIO xAPIC + x2APIC
//     Ref: AMD64 APM Vol.2 §16
// ============================================================================
module local_apic_regs (
    input  logic        clk, rst_n,
    input  logic        x2apic_en,   // 1 = modo x2APIC (MSR)
    // Acesso MMIO (xAPIC)
    input  logic        mmio_we,
    input  logic [11:0] mmio_addr,    // offset 0x000..0xFFF
    input  logic [31:0] mmio_wdata,
    output logic [31:0] mmio_rdata,
    // Acesso MSR (x2APIC)
    input  logic        msr_we,
    input  logic [31:0] msr_addr,     // 0x800..0x8FF
    input  logic [63:0] msr_wdata,
    output logic [63:0] msr_rdata
);
    // --- Identificação ---
    logic [31:0] apic_id;             // offset 0x020
    logic [31:0] apic_version;        // offset 0x030

    // --- Controle de prioridade ---
    logic [31:0] tpr;                 // offset 0x080
    logic [31:0] apr;                 // offset 0x090
    logic [31:0] ppr;                 // offset 0x0A0

    // --- Destinos ---
    logic [31:0] ldr;                 // offset 0x0D0
    logic [31:0] dfr;                 // offset 0x0E0
    logic [31:0] spur;                // offset 0x0F0

    // --- IRR / ISR / TMR (256 bits cada) ---
    logic [255:0] irr, isr, tmr;

    // --- ICR (64 bits) ---
    logic [63:0] icr;

    // --- LVTs ---
    logic [31:0] lvt_timer, lvt_thermal, lvt_perf,
                 lvt_lint0, lvt_lint1, lvt_error;

    // --- Timer ---
    logic [31:0] timer_init, timer_cur, timer_div;

    // --- Erro ---
    logic [31:0] esr;

    assign mmio_rdata = mmio_rd(mmio_addr);
    assign msr_rdata  = msr_rd(msr_addr);

    // ------------------------------------------------------------------------
    // MMIO read
    // ------------------------------------------------------------------------
    function automatic logic [31:0] mmio_rd(input logic [11:0] a);
        case (a)
            12'h020: mmio_rd = apic_id;
            12'h030: mmio_rd = apic_version;
            12'h080: mmio_rd = tpr;
            12'h090: mmio_rd = apr;
            12'h0A0: mmio_rd = ppr;
            12'h0D0: mmio_rd = ldr;
            12'h0E0: mmio_rd = dfr;
            12'h0F0: mmio_rd = spur;
            12'h280: mmio_rd = esr;
            12'h300: mmio_rd = icr[31:0];
            12'h310: mmio_rd = icr[63:32];
            12'h320: mmio_rd = lvt_timer;
            12'h330: mmio_rd = lvt_thermal;
            12'h340: mmio_rd = lvt_perf;
            12'h350: mmio_rd = lvt_lint0;
            12'h360: mmio_rd = lvt_lint1;
            12'h370: mmio_rd = lvt_error;
            12'h380: mmio_rd = timer_init;
            12'h390: mmio_rd = timer_cur;
            12'h3E0: mmio_rd = timer_div;
            // IRR/ISR/TMR em palavras de 32 bits
            12'h100,12'h110,12'h120,12'h130,12'h140,12'h150,12'h160,12'h170:
                mmio_rd = isr[((a - 12'h100)>>4)*32 +: 32];
            12'h180,12'h190,12'h1A0,12'h1B0,12'h1C0,12'h1D0,12'h1E0,12'h1F0:
                mmio_rd = tmr[((a - 12'h180)>>4)*32 +: 32];
            12'h200,12'h210,12'h220,12'h230,12'h240,12'h250,12'h260,12'h270:
                mmio_rd = irr[((a - 12'h200)>>4)*32 +: 32];
            default: mmio_rd = 32'h0;
        endcase
    endfunction

    // ------------------------------------------------------------------------
    // MSR read (x2APIC)
    // ------------------------------------------------------------------------
    function automatic logic [63:0] msr_rd(input logic [31:0] a);
        case (a)
            32'h802: msr_rd = {32'h0, apic_id};
            32'h803: msr_rd = {32'h0, apic_version};
            32'h808: msr_rd = {32'h0, tpr};
            32'h80D: msr_rd = {32'h0, ldr};
            32'h80F: msr_rd = {32'h0, spur};
            32'h828: msr_rd = {32'h0, esr};
            32'h830: msr_rd = icr;
            32'h832: msr_rd = {32'h0, lvt_timer};
            32'h833: msr_rd = {32'h0, lvt_thermal};
            32'h834: msr_rd = {32'h0, lvt_perf};
            32'h835: msr_rd = {32'h0, lvt_lint0};
            32'h836: msr_rd = {32'h0, lvt_lint1};
            32'h837: msr_rd = {32'h0, lvt_error};
            32'h838: msr_rd = {32'h0, timer_init};
            32'h839: msr_rd = {32'h0, timer_cur};
            32'h83E: msr_rd = {32'h0, timer_div};
            default: msr_rd = 64'h0;
        endcase
    endfunction

    // ------------------------------------------------------------------------
    // Reset e escritas
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            apic_id      <= 32'h0;
            apic_version <= 32'h80_00_00_10;
            tpr<=32'h0; apr<=32'h0; ppr<=32'h0;
            ldr<=32'h0; dfr<=32'hFFFF_FFFF; spur<=32'hFF;
            irr<=256'h0; isr<=256'h0; tmr<=256'h0;
            icr<=64'h0;
            lvt_timer<=32'h0001_0000;
            lvt_thermal<=32'h0001_0000;
            lvt_perf<=32'h0001_0000;
            lvt_lint0<=32'h0001_0000;
            lvt_lint1<=32'h0001_0000;
            lvt_error<=32'h0001_0000;
            timer_init<=32'h0; timer_cur<=32'h0; timer_div<=32'h0;
            esr<=32'h0;
        end else begin
            // Decrementa timer
            if (timer_cur != 0) timer_cur <= timer_cur - 1;

            // ----- MMIO writes (xAPIC) -----
            if (mmio_we) begin
                case (mmio_addr)
                    12'h080: tpr        <= mmio_wdata & 32'hFF;
                    12'h0D0: ldr        <= mmio_wdata;
                    12'h0E0: dfr        <= mmio_wdata;
                    12'h0F0: spur       <= mmio_wdata;
                    12'h280: esr        <= mmio_wdata;
                    12'h300: icr[31:0]  <= mmio_wdata;
                    12'h310: icr[63:32] <= mmio_wdata;
                    12'h320: lvt_timer  <= mmio_wdata;
                    12'h330: lvt_thermal<= mmio_wdata;
                    12'h340: lvt_perf   <= mmio_wdata;
                    12'h350: lvt_lint0  <= mmio_wdata;
                    12'h360: lvt_lint1  <= mmio_wdata;
                    12'h370: lvt_error  <= mmio_wdata;
                    12'h380: begin timer_init <= mmio_wdata; timer_cur <= mmio_wdata; end
                    12'h3E0: timer_div  <= mmio_wdata;
                    12'h0B0: begin
                        // EOI: limpa bit mais alto do ISR
                        for (int i = 255; i >= 0; i--) begin
                            if (isr[i]) begin isr[i] <= 1'b0; break; end
                        end
                    end
                    default: ;
                endcase
            end

            // ----- MSR writes (x2APIC) -----
            if (msr_we && x2apic_en) begin
                case (msr_addr)
                    32'h808: tpr        <= msr_wdata[31:0] & 32'hFF;
                    32'h80D: ldr        <= msr_wdata[31:0];
                    32'h80F: spur       <= msr_wdata[31:0];
                    32'h828: esr        <= msr_wdata[31:0];
                    32'h830: icr        <= msr_wdata;
                    32'h832: lvt_timer  <= msr_wdata[31:0];
                    32'h833: lvt_thermal<= msr_wdata[31:0];
                    32'h834: lvt_perf   <= msr_wdata[31:0];
                    32'h835: lvt_lint0  <= msr_wdata[31:0];
                    32'h836: lvt_lint1  <= msr_wdata[31:0];
                    32'h837: lvt_error  <= msr_wdata[31:0];
                    32'h838: begin timer_init <= msr_wdata[31:0]; timer_cur <= msr_wdata[31:0]; end
                    32'h83E: timer_div  <= msr_wdata[31:0];
                    32'h80B: begin
                        // EOI
                        for (int i = 255; i >= 0; i--) begin
                            if (isr[i]) begin isr[i] <= 1'b0; break; end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule


// ============================================================================
// 12) x87 + MMX — 8 registradores de 80 bits com stack TOP
//     Ref: AMD64 APM Vol.1 §6.2
// ============================================================================
module x87_stack (
    input  logic        clk, rst_n,
    input  logic        push_en, pop_en,
    input  logic [2:0]  st_idx,
    output logic [79:0] st0_o, sti_o,
    input  logic        ld_en, ld_top_en,
    input  logic [79:0] ld_data,
    input  logic        mmx_wr_en,
    input  logic [63:0] mmx_wdata,
    output logic [63:0] mmx_rdata,
    output logic [2:0]  top_o
);
    logic [79:0] fpr [8];
    logic [2:0]  top;
    assign top_o = top;

    // ST(0) e ST(i)
    assign st0_o = fpr[top];
    assign sti_o = fpr[(top + st_idx) & 7];

    // MMX = 64 bits baixos de FPRn (n = índice MMX)
    assign mmx_rdata = fpr[st_idx][63:0];

    // Registradores de ambiente (FCW/FSW/FTW) — simplificados
    logic [15:0] fcw, fsw, ftw;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 8; i++) fpr[i] <= 80'h0;
            top <= 3'd0;
            fcw <= 16'h0040;   // reset value
            fsw <= 16'h0000;
            ftw <= 16'h5555;
        end else begin
            if (push_en) begin
                top <= (top - 1) & 7;
                if (ld_top_en) fpr[(top - 1) & 7] <= ld_data;
            end
            if (pop_en) top <= (top + 1) & 7;
            if (ld_en)  fpr[(top + st_idx) & 7] <= ld_data;
            if (mmx_wr_en) begin
                fpr[st_idx][63:0] <= mmx_wdata;
                fpr[st_idx][79:64] <= 16'hFFFF;   // marca como "not finite"
            end
        end
    end
endmodule


// ============================================================================
// 13) Task Priority Register dedicado (CR8 shadow)
//     Ref: AMD64 APM Vol.2 §3.1.5
// ============================================================================
module tpr_cr8 (
    input  logic        clk, rst_n,
    input  logic        wr_en,
    input  logic [3:0]  tpr_i,
    output logic [3:0]  tpr_o
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          tpr_o <= 4'h0;
        else if (wr_en)      tpr_o <= tpr_i;
    end
endmodule

`default_nettype wire
