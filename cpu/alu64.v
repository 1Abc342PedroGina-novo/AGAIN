#include "register.v"

module alu64 (
    input  logic [63:0] a,
    input  logic [63:0] b,
    input  logic [5:0]  op,
    input  logic [1:0]  size,       // 00=8, 01=16, 10=32, 11=64
    input  logic        is_signed,  // IMUL/IDIV/SAR vs MUL/DIV/SHR
    input  logic        cin,        // carry-in (ADC/SBB/RCL/RCR)
    input  logic [5:0]  shift_amt,  // 0..63

    output logic [63:0] result,
    output logic [63:0] result_hi,  // high half para MUL/IMUL/DIV (RDX)
    output logic        div_by_zero,
    output logic        div_overflow,

    output logic        cf,
    output logic        pf,
    output logic        af,
    output logic        zf,
    output logic        sf,
    output logic        of
);

    // ------------------------------------------------------------------------
    // Opcodes
    // ------------------------------------------------------------------------
    localparam logic [5:0] OP_ADD  = 6'd0;
    localparam logic [5:0] OP_ADC  = 6'd1;
    localparam logic [5:0] OP_SUB  = 6'd2;
    localparam logic [5:0] OP_SBB  = 6'd3;
    localparam logic [5:0] OP_CMP  = 6'd4;
    localparam logic [5:0] OP_INC  = 6'd5;
    localparam logic [5:0] OP_DEC  = 6'd6;
    localparam logic [5:0] OP_NEG  = 6'd7;
    localparam logic [5:0] OP_MUL  = 6'd8;
    localparam logic [5:0] OP_IMUL = 6'd9;
    localparam logic [5:0] OP_DIV  = 6'd10;
    localparam logic [5:0] OP_IDIV = 6'd11;
    localparam logic [5:0] OP_AND  = 6'd12;
    localparam logic [5:0] OP_OR   = 6'd13;
    localparam logic [5:0] OP_XOR  = 6'd14;
    localparam logic [5:0] OP_NOT  = 6'd15;
    localparam logic [5:0] OP_TEST = 6'd16;
    localparam logic [5:0] OP_ANDN = 6'd17;
    localparam logic [5:0] OP_SHL  = 6'd18;
    localparam logic [5:0] OP_SHR  = 6'd19;
    localparam logic [5:0] OP_SAR  = 6'd20;
    localparam logic [5:0] OP_ROL  = 6'd21;
    localparam logic [5:0] OP_ROR  = 6'd22;
    localparam logic [5:0] OP_RCL  = 6'd23;
    localparam logic [5:0] OP_RCR  = 6'd24;
    localparam logic [5:0] OP_MOV  = 6'd25;

    // ------------------------------------------------------------------------
    // Máscaras e constantes por largura (tudo constante — Verilator-friendly)
    // ------------------------------------------------------------------------
    logic [63:0] mask;
    logic [6:0]  width;              // 8, 16, 32, 64
    logic [63:0] msb_mask;           // bit mais significativo da largura
    logic [63:0] max_pos;            // 0x7F..F
    logic [63:0] min_neg;            // 0x80..0
    logic [127:0] prod_high_mask;    // bits >= width em prod[127:0]

    always_comb begin
        unique case (size)
            2'b00: begin
                mask           = 64'h0000_0000_0000_00FF;
                width          = 7'd8;
                msb_mask       = 64'h0000_0000_0000_0080;
                max_pos        = 64'h0000_0000_0000_007F;
                min_neg        = 64'h0000_0000_0000_0080;
                prod_high_mask = 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FF00;
            end
            2'b01: begin
                mask           = 64'h0000_0000_0000_FFFF;
                width          = 7'd16;
                msb_mask       = 64'h0000_0000_0000_8000;
                max_pos        = 64'h0000_0000_0000_7FFF;
                min_neg        = 64'h0000_0000_0000_8000;
                prod_high_mask = 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_0000;
            end
            2'b10: begin
                mask           = 64'h0000_0000_FFFF_FFFF;
                width          = 7'd32;
                msb_mask       = 64'h0000_0000_8000_0000;
                max_pos        = 64'h0000_0000_7FFF_FFFF;
                min_neg        = 64'h0000_0000_8000_0000;
                prod_high_mask = 128'hFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0000;
            end
            default: begin
                mask           = 64'hFFFF_FFFF_FFFF_FFFF;
                width          = 7'd64;
                msb_mask       = 64'h8000_0000_0000_0000;
                max_pos        = 64'h7FFF_FFFF_FFFF_FFFF;
                min_neg        = 64'h8000_0000_0000_0000;
                prod_high_mask = 128'hFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0000;
            end
        endcase
    end

    logic [63:0] a_m, b_m;
    assign a_m = a & mask;
    assign b_m = b & mask;
  
      logic [63:0] a_signed_ext;
    assign a_signed_ext = a_sign ? (a_m | ~mask) : a_m;

    logic a_sign, b_sign, r_sign;
    assign a_sign = a_m[width - 1];
    assign b_sign = b_m[width - 1];

    // ------------------------------------------------------------------------
    // ADD / SUB (com carry-in)
    // ------------------------------------------------------------------------
    logic [64:0] add_ext, sub_ext;
    logic [63:0] sum, diff;

    assign add_ext = {1'b0, a_m} + {1'b0, b_m} + {64'h0, cin};
    assign sub_ext = {1'b0, a_m} - {1'b0, b_m} - {64'h0, cin};
    assign sum     = add_ext[63:0];
    assign diff    = sub_ext[63:0];

    // ------------------------------------------------------------------------
    // Lógica
    // ------------------------------------------------------------------------
    logic [63:0] r_and, r_or, r_xor, r_not, r_andn;
    assign r_and  = a_m & b_m;
    assign r_or   = a_m | b_m;
    assign r_xor  = a_m ^ b_m;
    assign r_not  = ~a_m;
    assign r_andn = (~a_m) & b_m;

    // ------------------------------------------------------------------------
    // Shift / Rotate
    // Usando máscaras e shifts; sem part-select variável.
    // ------------------------------------------------------------------------
    logic [63:0] shl, shr, sar, rol, ror, rcl, rcr;
    logic [64:0] rot_tmp;                        // 65 bits para RCL/RCR
    logic [6:0]  cnt;                            // declarado FORA do always_comb
    logic        shl_cf, shr_cf, sar_cf, rol_cf, ror_cf, rcl_cf, rcr_cf;

    always_comb begin
        // Defaults
        shl    = a_m;
        shr    = a_m;
        sar    = a_m;
        rol    = a_m;
        ror    = a_m;
        rcl    = a_m;
        rcr    = a_m;
        rot_tmp = {a_m, cin};
        shl_cf = 1'b0;
        shr_cf = 1'b0;
        sar_cf = 1'b0;
        rol_cf = 1'b0;
        ror_cf = 1'b0;
        rcl_cf = 1'b0;
        rcr_cf = 1'b0;
        cnt    = 7'd0;

        // Shift count efetivo (mascarado por width)
        if (width == 7'd64)
            cnt = {1'b0, shift_amt};
        else
            cnt = {2'b0, shift_amt[4:0]};
        if (width != 7'd0)
            cnt = cnt % width;

        unique case (op)
            OP_SHL: begin
                shl    = (a_m << cnt) & mask;
                // CF = último bit que saiu (bit width-cnt)
                shl_cf = (cnt != 0) ? a_m[width - cnt] : 1'b0;
            end
            OP_SHR: begin
                shr    = a_m >> cnt;
                shr_cf = (cnt != 0) ? a_m[cnt - 1] : 1'b0;
            end
            OP_SAR: begin
                // Extensão de sinal correta: a_signed_ext já é 64 bits signed
                sar    = ($signed(a_signed_ext) >>> cnt) & mask;
                sar_cf = (cnt != 0) ? a_m[cnt - 1] : 1'b0;
            end
            OP_ROL: begin
                if (cnt == 0)
                    rol = a_m;
                else
                    rol = ((a_m << cnt) | (a_m >> (width - cnt))) & mask;
                rol_cf = rol[0];
            end
            OP_ROR: begin
                if (cnt == 0)
                    ror = a_m;
                else
                    ror = ((a_m >> cnt) | (a_m << (width - cnt))) & mask;
                ror_cf = ror[width - 1];
            end
            OP_RCL: begin
                // {a_m, cin} rotacionado à esquerda por cnt
                rot_tmp = {a_m, cin};
                // Queremos bits [width:1] de rot_tmp (65 bits)
                // rot_tmp[1 +: width] é ilegal (width variável), então:
                // rcl = (rot_tmp >> 1) & mask  quando cnt = 0
                // Para cnt > 0, rotacionar rot_tmp[width:0] à esquerda.
                if (cnt == 0) begin
                    rcl = a_m;
                end else begin
                    logic [64:0] tmp65;
                    tmp65 = (rot_tmp << cnt) | (rot_tmp >> (width + 1 - cnt));
                    rcl   = tmp65[63:0] & mask;
                end
                rcl_cf = rot_tmp[width - cnt];
            end
            OP_RCR: begin
                // {cin, a_m} rotacionado à direita por cnt
                rot_tmp = {cin, a_m};
                if (cnt == 0) begin
                    rcr = a_m;
                end else begin
                    logic [64:0] tmp65;
                    tmp65 = (rot_tmp >> cnt) | (rot_tmp << (width + 1 - cnt));
                    rcr   = tmp65[63:0] & mask;
                end
                rcr_cf = rot_tmp[cnt - 1];
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------------
    // MUL / IMUL / DIV / IDIV
    // ------------------------------------------------------------------------
    logic [127:0] prod_u, prod_s;
    logic [127:0] prod;
    logic [127:0] prod_high;
    logic [127:0] prods_high;

    // Multiplicação: estender para 65 bits com sinal
    logic signed [64:0] a_sg, b_sg;
    assign a_sg = $signed({a_sign, a_m});
    assign b_sg = $signed({b_sign, b_m});

    assign prod_u = {64'h0, a_m} * {64'h0, b_m};
    assign prod_s = a_sg * b_sg;
    assign prod   = is_signed ? prod_s : prod_u;

    // Bits acima da largura efetiva
    assign prod_high  = prod   & prod_high_mask;

    // Divisão: dividendo = RDX:RAX (entrada em {b_m, a_m}), divisor = a_m
    // (o caller deve fornecer os operandos corretos; aqui usamos b como hi)
    logic [127:0] dividend_u;
    logic signed [127:0] dividend_se;
    logic [127:0] divisor_u;
    logic signed [127:0] divisor_se;
    logic [127:0] quo_u, rem_u;
    logic signed [127:0] quo_s, rem_s;

    assign dividend_u  = {b_m, a_m};                                  // 128 bits
    assign dividend_se = $signed({b_m, a_m});                         // 128 bits sinal
    assign divisor_u   = {64'h0, a_m};                                // 128 bits
    assign divisor_se  = $signed({{64{a_sign}}, a_m});                // 128 bits sinal

    always_comb begin
        quo_u = 128'h0;
        rem_u = 128'h0;
        if (divisor_u != 128'h0) begin
            quo_u = dividend_u / divisor_u;
            rem_u = dividend_u % divisor_u;
        end
    end

    always_comb begin
        quo_s = 128'sd0;
        rem_s = 128'sd0;
        if (divisor_se != 128'sd0) begin
            quo_s = dividend_se / divisor_se;
            rem_s = dividend_se % divisor_se;
        end
    end

    logic [63:0] quot, rem;
    assign quot = is_signed ? quo_s[63:0] : quo_u[63:0];
    assign rem  = is_signed ? rem_s[63:0] : rem_u[63:0];

    assign div_by_zero  = (a_m == 64'h0);
    assign div_overflow = is_signed
                        ? (dividend_se > $signed({64'h0, max_pos}))
                          || (dividend_se < $signed({{64{1'b1}}, min_neg}))
                        : (|dividend_u[127:64]);

    // ------------------------------------------------------------------------
    // Seleção do resultado
    // ------------------------------------------------------------------------
    always_comb begin
        result    = 64'h0;
        result_hi = 64'h0;

        unique case (op)
            OP_ADD, OP_ADC:              result = sum & mask;
            OP_SUB, OP_SBB, OP_CMP:      result = diff & mask;
            OP_INC:                      result = (a_m + 64'h1) & mask;
            OP_DEC:                      result = (a_m - 64'h1) & mask;
            OP_NEG:                      result = ((~a_m) + 64'h1) & mask;
            OP_MUL, OP_IMUL: begin
                result    = prod[63:0] & mask;
                result_hi = prod[127:64];
            end
            OP_DIV, OP_IDIV: begin
                result    = quot & mask;      // RAX
                result_hi = rem  & mask;      // RDX
            end
            OP_AND, OP_TEST:             result = r_and  & mask;
            OP_OR:                       result = r_or   & mask;
            OP_XOR:                      result = r_xor  & mask;
            OP_NOT:                      result = r_not  & mask;
            OP_ANDN:                     result = r_andn & mask;
            OP_SHL:                      result = shl    & mask;
            OP_SHR:                      result = shr    & mask;
            OP_SAR:                      result = sar    & mask;
            OP_ROL:                      result = rol    & mask;
            OP_ROR:                      result = ror    & mask;
            OP_RCL:                      result = rcl    & mask;
            OP_RCR:                      result = rcr    & mask;
            OP_MOV:                      result = b_m;
            default:                     result = 64'h0;
        endcase
    end

    // ------------------------------------------------------------------------
    // Flags
    // ------------------------------------------------------------------------
    logic [63:0] r_eff;
    assign r_eff  = result & mask;
    assign r_sign = r_eff[width - 1];

    // ---------- CF ----------
    logic cf_add, cf_sub, cf_mul, cf_imul, cf_shl, cf_shr, cf_rol, cf_ror;

    assign cf_add  = add_ext[64];
    assign cf_sub  = sub_ext[64];
    assign cf_mul  = |prod_high;
        // Limites representáveis na largura efetiva, estendidos para 128 bits signed
logic signed [127:0] imul_max, imul_min;
always_comb begin
    unique case (width)
        7'd8: begin
            imul_max =  128'sd127;
            imul_min = -128'sd128;              // -128
        end
        7'd16: begin
            imul_max =  128'sd32767;
            imul_min = -128'sd32768;            // -32768
        end
        7'd32: begin
            imul_max =  128'sd2147483647;
            imul_min = -128'sd2147483648;       // -2147483648
        end
        7'd64: begin
            imul_max =  128'sd9223372036854775807;   // 2^63 - 1
            imul_min = -128'sd9223372036854775808;   // -2^63
        end
        default: begin
            imul_max = 128'sd0;
            imul_min = 128'sd0;
        end
    endcase
end

    assign cf_imul = (prod_s > imul_max) || (prod_s < imul_min);
    assign cf_shl  = shl_cf;
    assign cf_shr  = shr_cf;
    assign cf_rol  = rol_cf;
    assign cf_ror  = ror_cf;

    always_comb begin
        cf = 1'b0;
        unique case (op)
            OP_ADD, OP_ADC:              cf = cf_add;
            OP_SUB, OP_SBB, OP_CMP:      cf = cf_sub;
            OP_NEG:                      cf = (a_m != 64'h0);
            OP_INC, OP_DEC:              cf = cf;         // preserva
            OP_MUL:                      cf = cf_mul;
            OP_IMUL:                     cf = cf_imul;
            OP_AND, OP_OR, OP_XOR,
            OP_NOT, OP_TEST, OP_ANDN:    cf = 1'b0;
            OP_SHL:                      cf = cf_shl;
            OP_SHR:                      cf = cf_shr;
            OP_SAR:                      cf = cf_shr;
            OP_ROL:                      cf = cf_rol;
            OP_ROR:                      cf = cf_ror;
            OP_RCL:                      cf = rcl_cf;
            OP_RCR:                      cf = rcr_cf;
            default:                     cf = 1'b0;
        endcase
    end

    // ---------- PF ----------
    assign pf = ~^r_eff[7:0];

    // ---------- AF ----------
    logic af_add, af_sub;
    assign af_add = add_ext[4];
    assign af_sub = sub_ext[4];

    always_comb begin
        af = 1'b0;
        unique case (op)
            OP_ADD, OP_ADC:              af = af_add;
            OP_SUB, OP_SBB, OP_CMP:      af = af_sub;
            OP_NEG:                      af = (a_m[3:0] != 4'h0);
            OP_INC:                      af = ((a_m[3:0] + 4'h1) > 4'hF);
            OP_DEC:                      af = (a_m[3:0] == 4'h0);
            default:                     af = 1'b0;
        endcase
    end

    // ---------- ZF ----------
    assign zf = (r_eff == 64'h0);

    // ---------- SF ----------
    assign sf = r_sign;

    // ---------- OF ----------
    logic of_add, of_sub, of_mul, of_imul, of_inc, of_dec, of_neg;
    logic of_shl, of_shr, of_sar, of_rol, of_ror;

    assign of_add  = (~a_sign & ~b_sign &  r_sign) |
                     ( a_sign &  b_sign & ~r_sign);
    assign of_sub  = (~a_sign &  b_sign &  r_sign) |
                     ( a_sign & ~b_sign & ~r_sign);
    assign of_mul  = cf_mul;
    assign of_imul = cf_imul;
    assign of_inc  = (a_m == max_pos);
    assign of_dec  = (a_m == min_neg);
    assign of_neg  = (a_m == min_neg);
    assign of_shl  = cf_shl ^ r_sign;
    assign of_shr  = a_sign;
    assign of_sar  = 1'b0;
    assign of_rol  = (cnt == 7'd1) ? (rol[width - 1] ^ rol[width - 2]) : 1'b0;
    assign of_ror  = (cnt == 7'd1) ? (ror[width - 1] ^ ror[width - 2]) : 1'b0;

    always_comb begin
        of = 1'b0;
        unique case (op)
            OP_ADD, OP_ADC:              of = of_add;
            OP_SUB, OP_SBB, OP_CMP:      of = of_sub;
            OP_NEG:                      of = of_neg;
            OP_INC:                      of = of_inc;
            OP_DEC:                      of = of_dec;
            OP_MUL:                      of = of_mul;
            OP_IMUL:                     of = of_imul;
            OP_AND, OP_OR, OP_XOR,
            OP_NOT, OP_TEST, OP_ANDN:    of = 1'b0;
            OP_SHL:                      of = of_shl;
            OP_SHR:                      of = of_shr;
            OP_SAR:                      of = of_sar;
            OP_ROL:                      of = of_rol;
            OP_ROR:                      of = of_ror;
            OP_RCL, OP_RCR:              of = 1'b0;   // indefinido no APM
            OP_DIV, OP_IDIV:             of = 1'b0;   // indefinido no APM
            default:                     of = 1'b0;
        endcase
    end

endmodule
