/* cpld_ram512K
 *
 * CPLD module to implement all logic for an Amstrad CPC 512K RAM extension card
 *
 * (c) 2018, Revaldinho
 *
 * Select RAM bank scheme by writing to 0x7FXX with 0b11cccbbb, where:
 * 
 * ccc - picks one of 8 possible 64K banks
 * bbb - selects a block switching scheme within the chosen bank
 *       the actual block used for a RAM access is then selected by the top 2 addr bits for that access.
 *
 * 128K RAM Expansion Mapping Example...
 *
 * In the table below '-' indicates use of CPC internal RAM rather than the RAM expansion
 * -------------------------------------------------------------------------------------------------------------------------------
 * Address\cccbbb 000000 000001 000010 000011 000100 000101 000110 000011 001000 001001 001010 001011 001100 001101 001110 001111
 * -------------------------------------------------------------------------------------------------------------------------------
 * 1100-1111       -       3      3      3      -      -      -      -      -      7       7      7     -      -      -      -
 * 1000-1011       -       -      2      -      -      -      -      -      -      -       6      -     -      -      -      -
 * 0100-0111       -       -      1      -      0      1       2      3     -      -       5      -     4      5      6      7
 * 0000-0011       -       -      0      -      -      -      -      -      -      -       4      -     -      -      -      -
 * -------------------------------------------------------------------------------------------------------------------------------
 *
 */

`define OVERDRIVE 1



module cpld_ram512k_overdrive(rfsh_b,adr15,adr14,iorq_b,mreq_b,ramrd_b,reset_b,wr_b,rd_b,data,ramdis,ramcs_b,ramadrhi,ready, clk, ramoe_b, ramwe_b);
  input            rfsh_b;
  inout            adr15;    
  input            adr14;
  input            iorq_b;
  input            mreq_b;
  input            ramrd_b;
  input            reset_b;
  input            wr_b;
  inout            rd_b;    
  input [7:0]      data;
  input            ready;
  input            clk;
  
  
  output           ramdis;
  output           ramcs_b;
  output [4:0]     ramadrhi;
  output           ramoe_b;
  output           ramwe_b;
  
  reg [5:0]        ramblock_q;
  reg [2:0]        hibit_tmp_r;  
  reg [4:0]        ramadrhi_r;
  reg              ramcs_b_r;
  reg              clken_lat_qb;
  reg              adr15_q;
  reg              mreq_b_q;
  reg              mwr_cyc_q;
  reg              exp_ram_r;   
  reg              shadow_en_b_r;

  wire             overdrive_mode = 1'b1; // (aka  464 mode) enable only on 464/664
  wire             shadow_mode = 1'b1;    // enable only on 464/664
  wire [2:0]       shadow_bank = 3'b111; // use 3'b111 or 3'b011

  parameter IDLE=2'b00, WM0=2'b11, WM1=2'b10, END=2'b01;
  // Create negedge clock on IO write event - clock low pulse will be suppressed if not an IOWR* event
  // but if the pulse is allowed through use the trailing (rising) edge to capture data
  wire             wclk    = !(clk|clken_lat_qb); 

  // Combination of RAMCS and RAMRD determine whether RAM output is enabled
  assign ramoe_b = ramrd_b ;		
  assign ramdis  = !ramcs_b_r ;  
  assign ramadrhi = ramadrhi_r ;
  assign ramcs_b = ramcs_b_r  | (mreq_b & ramrd_b);  
  assign ramwe_b = wr_b ;

  //          ____      ____      ____      ____      ____  
  // CLK     /    \____/    \____/    \____/    \____/    \_
  //         _____     :    .         .         .   ________
  // MREQ*        \________________________________/ :    .
  //         _______________________________________________
  // RFSH*   1         :    .         .         .    :    .
  //         _________________        .         .  _________
  // WR*               :    . \___________________/  :    .    
  //         _____________       ___________________________
  // READY             :  \_____/      
  //                   :    .         .         .    :    .
  //                   :_____________________________:    .        
  // MWR_CYC    _______/    .         .         .    \______
  // 

  // overdrive A15 HIGH only in mode 3 when address is 0x4000-0x0x7FFF and valid WRITE mcycle -> write will go to RAM
  // For read cycles dont overdrive A15 as the remapping for the RAM read will come from shadow memory to avoid clash with enabled upper ROM
  assign adr15 = ( overdrive_mode ) ? (((ramblock_q[2:0]==3'b011) & adr14 & mwr_cyc_q) ? 1'b1 : 1'bz) : 1'bz;  
  assign rd_b  = ( overdrive_mode ) ? ( exp_ram_r & mwr_cyc_q & !mreq_b) ? 1'b0 : 1'bz : 1'bz;

  always @ ( negedge reset_b or posedge clk )
    if ( !reset_b) begin
      mwr_cyc_q <= 1'b0;
      mreq_b_q <= 1'b1;                                      
    end                                     
    else begin
      mreq_b_q <= mreq_b;                                     
      if ( !mreq_b & mreq_b_q & rfsh_b & rd_b)
        mwr_cyc_q <= 1'b1;
      else if ( mreq_b  )
        mwr_cyc_q <= 1'b0;
    end // else: !if( !reset_b)
  
  always @ (negedge reset_b or negedge mreq_b ) 
    if ( !reset_b ) 
      adr15_q <= 1'b0;
    else
      adr15_q <= adr15;
  
  always @ ( * )
    if ( clk ) 
      clken_lat_qb <= !(!iorq_b && !wr_b && !adr15 && data[6] && data[7]);
  
  always @ (negedge reset_b or posedge wclk )
    if (!reset_b)
      ramblock_q <= 6'b0;
    else
      ramblock_q <= data[5:0];
  

  always @ ( * ) begin
    if ( shadow_mode ) begin  
      // _write_ shadow RAM only at &Cxxx-&Fxxx in all modes except C3 which is handled in the case statement (and may need to read also)
      shadow_en_b_r = !((!wr_b) & adr15_q & adr14);
      hibit_tmp_r = ramblock_q[5:3] ;
      if ( (ramblock_q[5:3] == shadow_bank))
        hibit_tmp_r[0] = 1'b0;        
      case (ramblock_q[2:0])
 	3'b000: {exp_ram_r, ramcs_b_r, ramadrhi_r} = { 1'b0, shadow_en_b_r , shadow_bank, 2'b11 };
 	3'b001: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15_q,adr14}==2'b11 ) ? {1'b1, 1'b0, hibit_tmp_r,2'b11} : { 2'b01, 5'bxxxxx };
 	3'b010: {exp_ram_r, ramcs_b_r, ramadrhi_r} = { 1'b1, 1'b0,hibit_tmp_r,adr15_q,adr14} ; 
 	3'b011: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15_q,adr14}==2'b11 ) ? {2'b10,hibit_tmp_r,2'b11} : ({adr15_q,adr14}==2'b01) ? {2'b00,shadow_bank,2'b11} : {2'b01, 5'bxxxxx};
 	3'b100: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15_q,adr14}==2'b01 ) ? {2'b10,hibit_tmp_r,2'b00} : { 1'b0, shadow_en_b_r , shadow_bank, 2'b11 };              
 	3'b101: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15_q,adr14}==2'b01 ) ? {2'b10,hibit_tmp_r,2'b01} : { 1'b0, shadow_en_b_r , shadow_bank, 2'b11 };              
 	3'b110: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15_q,adr14}==2'b01 ) ? {2'b10,hibit_tmp_r,2'b10} : { 1'b0, shadow_en_b_r , shadow_bank, 2'b11 };              
 	3'b111: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15_q,adr14}==2'b01 ) ? {2'b10,hibit_tmp_r,2'b11} : { 1'b0, shadow_en_b_r , shadow_bank, 2'b11 };
      endcase // case (hibit_tmp_r[2:0])

    end
    else begin
      case (ramblock_q[2:0])
 	3'b000: {exp_ram_r, ramcs_b_r, ramadrhi_r} = { 2'b01, 5'bxxxxx };
 	3'b001: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15,adr14}==2'b11 ) ? {2'b10,ramblock_q[5:3],2'b11} : {2'b01, 5'bxxxxx};
 	3'b010: {exp_ram_r, ramcs_b_r, ramadrhi_r} = { 2'b10,ramblock_q[5:3],adr15,adr14} ; 
 	3'b011: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15,adr14}==2'b11 ) ? {2'b10,ramblock_q[5:3],2'b11} : {2'b01, 5'bxxxxx };
 	3'b100: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15,adr14}==2'b01 ) ? {2'b10,ramblock_q[5:3],2'b00} : {2'b01, 5'bxxxxx };              
 	3'b101: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15,adr14}==2'b01 ) ? {2'b10,ramblock_q[5:3],2'b01} : {2'b01, 5'bxxxxx };              
 	3'b110: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15,adr14}==2'b01 ) ? {2'b10,ramblock_q[5:3],2'b10} : {2'b01, 5'bxxxxx };              
 	3'b111: {exp_ram_r, ramcs_b_r, ramadrhi_r} = ( {adr15,adr14}==2'b01 ) ? {2'b10,ramblock_q[5:3],2'b11} : {2'b01, 5'bxxxxx };
      endcase 
    end	    
  end
  
endmodule