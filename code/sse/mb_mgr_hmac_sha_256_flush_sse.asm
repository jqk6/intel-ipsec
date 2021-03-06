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

extern sha_256_mult_sse

%ifndef FUNC
%define FUNC flush_job_hmac_sha_256_sse
%endif

%if 1
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


; idx needs to be in rbx, rbp, r13-r15
%define idx		rbp

%define unused_lanes	rbx
%define lane_data	rbx
%define tmp2		rbx
	    
%define job_rax		rax
%define	tmp1		rax
%define size_offset	rax
%define tmp		rax
%define start_offset	rax
	    
%define tmp3		arg1
	    
%define extra_blocks	arg2
%define p		arg2

%define tmp4		r8

%define tmp5	        r9

%define tmp6	        r10

%endif

; This routine clobbers rbx, rbp; called routine also clobbers r12
struc STACK
_gpr_save:	resq	3
_rsp_save:	resq	1
endstruc

%define APPEND(a,b) a %+ b

; JOB* FUNC(MB_MGR_HMAC_SHA_256_OOO *state)
; arg 1 : rcx : state
global FUNC :function
FUNC:

	mov	rax, rsp
	sub	rsp, STACK_size
	and	rsp, -16

	mov	[rsp + _gpr_save + 8*0], rbx
	mov	[rsp + _gpr_save + 8*1], rbp
	mov	[rsp + _gpr_save + 8*2], r12
	mov	[rsp + _rsp_save], rax	; original SP

	mov	unused_lanes, [state + _unused_lanes_sha256]
	bt	unused_lanes, 32+7
	jc	return_null

	; find a lane with a non-null job
	xor	idx, idx
	cmp	qword [state + _ldata_sha256 + 1 * _HMAC_SHA1_LANE_DATA_size + _job_in_lane], 0
	cmovne	idx, [one wrt rip]
	cmp	qword [state + _ldata_sha256 + 2 * _HMAC_SHA1_LANE_DATA_size + _job_in_lane], 0
	cmovne	idx, [two wrt rip]
	cmp	qword [state + _ldata_sha256 + 3 * _HMAC_SHA1_LANE_DATA_size + _job_in_lane], 0
	cmovne	idx, [three wrt rip]

copy_lane_data:	
	; copy idx to empty lanes
	movdqa	xmm0, [state + _lens_sha256]
	mov	tmp, [state + _args_data_ptr_sha256 + 8*idx]

%assign I 0
%rep 4
	cmp	qword [state + _ldata_sha256 + I * _HMAC_SHA1_LANE_DATA_size + _job_in_lane], 0
	jne	APPEND(skip_,I)
	mov	[state + _args_data_ptr_sha256 + 8*I], tmp
	por	xmm0, [len_masks + 16*I wrt rip]
APPEND(skip_,I):
%assign I (I+1)
%endrep
    
	movdqa	[state + _lens_sha256], xmm0

	phminposuw	xmm1, xmm0
	pextrw	len2, xmm1, 0	; min value
	pextrw	idx, xmm1, 1	; min index (0...3)
	cmp	len2, 0
	je	len_is_0

	pshuflw	xmm1, xmm1, 0
	psubw	xmm0, xmm1
	movdqa	[state + _lens_sha256], xmm0

	; "state" and "args" are the same address, arg1
	; len is arg2
	call	sha_256_mult_sse
	; state and idx are intact

len_is_0:
	; process completed job "idx"
	imul	lane_data, idx, _HMAC_SHA1_LANE_DATA_size
	lea	lane_data, [state + _ldata_sha256 + lane_data]
	mov	DWORD(extra_blocks), [lane_data + _extra_blocks]
	cmp	extra_blocks, 0
	jne	proc_extra_blocks
	cmp	dword [lane_data + _outer_done], 0
	jne	end_loop

proc_outer:
	mov	dword [lane_data + _outer_done], 1
	mov	DWORD(size_offset), [lane_data + _size_offset]
	mov	qword [lane_data + _extra_block + size_offset], 0
	mov	word [state + _lens_sha256 + 2*idx], 1
	lea	tmp, [lane_data + _outer_block]
	mov	job, [lane_data + _job_in_lane]
	mov	[state + _args_data_ptr_sha256 + 8*idx], tmp

	movd	xmm0, [state + _args_digest_sha256 + 4*idx + 0*SHA256_DIGEST_ROW_SIZE]
	pinsrd	xmm0, [state + _args_digest_sha256 + 4*idx + 1*SHA256_DIGEST_ROW_SIZE], 1
	pinsrd	xmm0, [state + _args_digest_sha256 + 4*idx + 2*SHA256_DIGEST_ROW_SIZE], 2
	pinsrd	xmm0, [state + _args_digest_sha256 + 4*idx + 3*SHA256_DIGEST_ROW_SIZE], 3
	pshufb	xmm0, [byteswap wrt rip]
	movd	xmm1, [state + _args_digest_sha256 + 4*idx + 4*SHA256_DIGEST_ROW_SIZE]
	pinsrd	xmm1, [state + _args_digest_sha256 + 4*idx + 5*SHA256_DIGEST_ROW_SIZE], 1
	pinsrd	xmm1, [state + _args_digest_sha256 + 4*idx + 6*SHA256_DIGEST_ROW_SIZE], 2
%ifndef SHA224
	pinsrd	xmm1, [state + _args_digest_sha256 + 4*idx + 7*SHA256_DIGEST_ROW_SIZE], 3
%endif
	pshufb	xmm1, [byteswap wrt rip]
	movdqa	[lane_data + _outer_block], xmm0
	movdqa	[lane_data + _outer_block + 4*4], xmm1
%ifdef SHA224
	mov		dword [lane_data + _outer_block + 7*4], 0x80
%endif

	mov	tmp, [job + _auth_key_xor_opad]
	movdqu	xmm0, [tmp]
	movdqu	xmm1, [tmp + 4*4]
	movd	[state + _args_digest_sha256 + 4*idx + 0*SHA256_DIGEST_ROW_SIZE], xmm0
	pextrd	[state + _args_digest_sha256 + 4*idx + 1*SHA256_DIGEST_ROW_SIZE], xmm0, 1
	pextrd	[state + _args_digest_sha256 + 4*idx + 2*SHA256_DIGEST_ROW_SIZE], xmm0, 2
	pextrd	[state + _args_digest_sha256 + 4*idx + 3*SHA256_DIGEST_ROW_SIZE], xmm0, 3
	movd	[state + _args_digest_sha256 + 4*idx + 4*SHA256_DIGEST_ROW_SIZE], xmm1
	pextrd	[state + _args_digest_sha256 + 4*idx + 5*SHA256_DIGEST_ROW_SIZE], xmm1, 1
	pextrd	[state + _args_digest_sha256 + 4*idx + 6*SHA256_DIGEST_ROW_SIZE], xmm1, 2
	pextrd	[state + _args_digest_sha256 + 4*idx + 7*SHA256_DIGEST_ROW_SIZE], xmm1, 3
	jmp	copy_lane_data

	align	16
proc_extra_blocks:
	mov	DWORD(start_offset), [lane_data + _start_offset]
	mov	[state + _lens_sha256 + 2*idx], WORD(extra_blocks)
	lea	tmp, [lane_data + _extra_block + start_offset]
	mov	[state + _args_data_ptr_sha256 + 8*idx], tmp
	mov	dword [lane_data + _extra_blocks], 0
	jmp	copy_lane_data

return_null:
	xor	job_rax, job_rax
	jmp	return
    
	align	16
end_loop:
	mov	job_rax, [lane_data + _job_in_lane]
	mov	qword [lane_data + _job_in_lane], 0
	or	dword [job_rax + _status], STS_COMPLETED_HMAC
	mov	unused_lanes, [state + _unused_lanes_sha256]
	shl	unused_lanes, 8
	or	unused_lanes, idx
	mov	[state + _unused_lanes_sha256], unused_lanes

	mov	p, [job_rax + _auth_tag_output]

	; copy 14 bytes for SHA224 and 16 bytes for SHA256 
	mov	DWORD(tmp2), [state + _args_digest_sha256 + 4*idx + 0*SHA256_DIGEST_ROW_SIZE]
	mov	DWORD(tmp4), [state + _args_digest_sha256 + 4*idx + 1*SHA256_DIGEST_ROW_SIZE]
	mov	DWORD(tmp6), [state + _args_digest_sha256 + 4*idx + 2*SHA256_DIGEST_ROW_SIZE]
	mov	DWORD(tmp5), [state + _args_digest_sha256 + 4*idx + 3*SHA256_DIGEST_ROW_SIZE]
	
	bswap	DWORD(tmp2)
	bswap	DWORD(tmp4)
	bswap	DWORD(tmp6)
	bswap	DWORD(tmp5)

	mov	[p + 0*4], DWORD(tmp2)
	mov	[p + 1*4], DWORD(tmp4)
	mov	[p + 2*4], DWORD(tmp6)

%ifdef SHA224
	mov	[p + 3*4], WORD(tmp5)
%else
	mov	[p + 3*4], DWORD(tmp5)
%endif

return:

	mov	rbx, [rsp + _gpr_save + 8*0]
	mov	rbp, [rsp + _gpr_save + 8*1]
	mov	r12, [rsp + _gpr_save + 8*2]
	mov	rsp, [rsp + _rsp_save]	; original SP

	ret

section .data
align 16
byteswap:	ddq 0x0c0d0e0f08090a0b0405060700010203
len_masks:
	ddq 0x0000000000000000000000000000FFFF
	ddq 0x000000000000000000000000FFFF0000
	ddq 0x00000000000000000000FFFF00000000
	ddq 0x0000000000000000FFFF000000000000
one:	dq  1
two:	dq  2
three:	dq  3
