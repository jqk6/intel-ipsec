;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Copyright (c) 2015, Intel Corporation 
; 
; All rights reserved. 
; 
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions are
; met: 
; 
; * Redistributions of source code must retain the above copyright
;   notice, this list of conditions and the following disclaimer.  
; 
; * Redistributions in binary form must reproduce the above copyright
;   notice, this list of conditions and the following disclaimer in the
;   documentation and/or other materials provided with the
;   distribution. 
; 
; * Neither the name of the Intel Corporation nor the names of its
;   contributors may be used to endorse or promote products derived from
;   this software without specific prior written permission. 
; 
; 
; THIS SOFTWARE IS PROVIDED BY INTEL CORPORATION ""AS IS"" AND ANY
; EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
; PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL INTEL CORPORATION OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
; EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
; PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
; PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
; LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

%include "job_aes_hmac.asm"
%include "mb_mgr_datastruct.asm"

%include "reg_sizes.asm"

%ifndef AES_CBC_ENC_X8
%define AES_CBC_ENC_X8 aes_cbc_enc_128_x8
%define SUBMIT_JOB_AES_ENC submit_job_aes128_enc_avx
%endif

; void AES_CBC_ENC_X8(AES_ARGS_x8 *args, UINT64 len_in_bytes);
extern AES_CBC_ENC_X8

%ifdef LINUX
%define arg1	rdi
%define arg2	rsi
%else
%define arg1	rcx
%define arg2	rdx
%endif

%define state	arg1
%define job	arg2
%define len2	arg2
	
%define job_rax          rax

%if 1
; idx needs to be in rbp
%define len              rbp
%define idx              rbp
%define tmp              rbp

%define lane             r8

%define iv               r9

%define unused_lanes     rbx
%endif

; STACK_SPACE needs to be an odd multiple of 8
; This routine and its callee clobbers all GPRs
struc STACK
_gpr_save:	resq	8
_rsp_save:	resq	1
endstruc

; JOB* SUBMIT_JOB_AES_ENC(MB_MGR_AES_OOO *state, JOB_AES_HMAC *job)
; arg 1 : state
; arg 2 : job
global SUBMIT_JOB_AES_ENC :function
SUBMIT_JOB_AES_ENC:

        mov	rax, rsp
        sub	rsp, STACK_size
        and	rsp, -16

	mov	[rsp + _gpr_save + 8*0], rbx
	mov	[rsp + _gpr_save + 8*1], rbp
	mov	[rsp + _gpr_save + 8*2], r12
	mov	[rsp + _gpr_save + 8*3], r13
	mov	[rsp + _gpr_save + 8*4], r14
	mov	[rsp + _gpr_save + 8*5], r15
%ifndef LINUX
	mov	[rsp + _gpr_save + 8*6], rsi
	mov	[rsp + _gpr_save + 8*7], rdi
%endif
	mov	[rsp + _rsp_save], rax	; original SP

	mov	unused_lanes, [state + _aes_unused_lanes]
	mov	lane, unused_lanes
	and	lane, 0xF
	shr	unused_lanes, 4
	mov	len, [job + _msg_len_to_cipher_in_bytes]
	mov	iv, [job + _iv]
	mov	[state + _aes_unused_lanes], unused_lanes

	mov	[state + _aes_job_in_lane + lane*8], job
	mov	[state + _aes_lens + 2*lane], WORD(len)

	mov	tmp, [job + _src]
	add	tmp, [job + _cipher_start_src_offset_in_bytes]
	vmovdqu	xmm0, [iv]
	mov	[state + _aes_args_in + lane*8], tmp
	mov	tmp, [job + _aes_enc_key_expanded]
	mov	[state + _aes_args_keys + lane*8], tmp
	mov	tmp, [job + _dst]
	mov	[state + _aes_args_out + lane*8], tmp
	shl	lane, 4	; multiply by 16
	vmovdqa	[state + _aes_args_IV + lane], xmm0

	cmp	unused_lanes, 0xf
	jne	return_null

	; Find min length
	vmovdqa	xmm0, [state + _aes_lens]
	vphminposuw	xmm1, xmm0
	vpextrw	DWORD(len2), xmm1, 0	; min value
	vpextrw	DWORD(idx), xmm1, 1	; min index (0...7)
	cmp	len2, 0
	je	len_is_0

	vpshufb	xmm1, xmm1, [dupw wrt rip]   ; duplicate words across all lanes
	vpsubw	xmm0, xmm0, xmm1
	vmovdqa	[state + _aes_lens], xmm0

	; "state" and "args" are the same address, arg1
	; len is arg2
	call	AES_CBC_ENC_X8
	; state and idx are intact

len_is_0:
	; process completed job "idx"
	mov	job_rax, [state + _aes_job_in_lane + idx*8]
; Don't write back IV
;	mov	iv, [job_rax + _iv]
	mov	unused_lanes, [state + _aes_unused_lanes]
	mov	qword [state + _aes_job_in_lane + idx*8], 0
	or	dword [job_rax + _status], STS_COMPLETED_AES
	shl	unused_lanes, 4
	or	unused_lanes, idx
;	shl	idx, 4 ; multiply by 16
	mov	[state + _aes_unused_lanes], unused_lanes
;	vmovdqa	xmm0, [state + _aes_args_IV + idx]
;	vmovdqu	[iv], xmm0

return:

	mov	rbx, [rsp + _gpr_save + 8*0]
	mov	rbp, [rsp + _gpr_save + 8*1]
	mov	r12, [rsp + _gpr_save + 8*2]
	mov	r13, [rsp + _gpr_save + 8*3]
	mov	r14, [rsp + _gpr_save + 8*4]
	mov	r15, [rsp + _gpr_save + 8*5]
%ifndef LINUX
	mov	rsi, [rsp + _gpr_save + 8*6]
	mov	rdi, [rsp + _gpr_save + 8*7]
%endif
	mov	rsp, [rsp + _rsp_save]	; original SP

	ret

return_null:
	xor	job_rax, job_rax
	jmp	return

section .data
align 16
dupw:
	ddq 0x01000100010001000100010001000100