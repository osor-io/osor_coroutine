


#module_parameters(ASSERT := true, GUARD_PAGES := true);
#if ASSERT #import "Basic";
else assert :: (arg: bool, message := "", args: .. Any, loc := #caller_location) #expand {}



//
// This is a simple x64 resumable procedure implementation. Some people call them
// asymmetric coroutines as well.
//
// The gist is that you're able to call a procedure with run(), then this procedure runs for a while
// until it calls yield() and "returns" to the caller. Next time you call run(), the procedure will
// start back in the instruction immediately following the previous yield() call.
//
// See example.jai for more details.
//
// Some notes about which threads can call these and the context:
//
// About the Jai context and threading. This is slightly fiddly to work with and I haven't made a
// decission about what context should a given coroutine be using. I suppose that ideally it would use
// whatever context is in the thread the user is calling run() on, but switching (jai) contexts is not easy here
// and it would require me to know exactly where in the stack and/or which register has the context pointer at
// any time. At the time of writing this is also subject to change in the language.
//
// Right now, the context used on the coroutine is the one from the thread that calls init(), and then the
// user is expected to always call run() from that same thread. This makes it so we don't have to worry where
// the context is accessed from when switching to the coroutine, it'll be just a normal register. Although it
// has the disadvantage that we need to keep some things in check, like context.stack_trace.
//
// The other option that also seems sensible is to have each coroutine have its own context. This would probably
// end up being simpler. Since we don't worry then about stuff like context.stack_trace. And it would even allow
// us to call the coroutine from different threads in different run() calls. But this is also tricky in some sense.
// I want this to be a simple implementation and very transparent to the user, if a different context which you can't
// easily access just happens to appear, this can lead to confusion and bugs. The idea of a "context" in Jai is also
// quite tied to the current thread, plus what would happen with temporary storage? I don't like the ramifications
// of having a separate hidden context.
//
// I suppose the true best way would be to transparently switch to whatever context the thread that calls run() has, but
// in the middle of the procedure, when calling yield, the context could be in any register, or somewhere in the stack that
// we don't know, so unless there's a way to explicitly change the context pointer, we can't have it use the context from any
// thread. I don't think push_context works in this sense, because it appears scoped and does more complex stuff like some initialization
// and some changes on the context based on the x64 assembly I'm seeing, so it's not the same as just setting the stack and
// the appropriate registers. 
//
// So yeah, for now a single coroutine is meant to be called from one thread. This is set on the thread that initializes it
// and we assert that this is being followed. This is because init() reads the context pointer already to set up the beginning
// of the coroutine so both init() and all the run() calls for a given coroutine need to be on that same thread.
//
//                                                                       - Ruben Osorio, 04/01/2023
//



Coroutine :: struct
{
    main_context : Coroutine_Context #align 16;
    back_context : Coroutine_Context #align 16;

    procedure : #type ();
    user_data : *void;
    stack_allocation : []u8;
    done := false;

    #if ASSERT thread_index : u32;
}

init :: (coroutine : *Coroutine, procedure : #type (), user_data : *void = null, requested_stack_size := 64*1024)
{
    <<coroutine = Coroutine.{}; 
    coroutine.procedure = procedure;
    coroutine.user_data = user_data;
    #if ASSERT coroutine.thread_index = context.thread_index;
    platform_init(coroutine, requested_stack_size);
}

deinit :: (coroutine : *Coroutine)
{
    platform_deinit(coroutine);
}

#add_context current_coroutine : *Coroutine = null;

run :: (coroutine : *Coroutine)
{
    #if ASSERT assert(coroutine.thread_index == context.thread_index);
    caller_coroutine := context.current_coroutine;
    context.current_coroutine = coroutine;
    switch_context(from = *coroutine.back_context, to = *coroutine.main_context, *context);
    context.current_coroutine = caller_coroutine;
}

yield :: ()
{
    assert(context.current_coroutine != null);
    #if ASSERT assert(context.current_coroutine.thread_index == context.thread_index);
    switch_context(from = *context.current_coroutine.main_context, to = *context.current_coroutine.back_context, *context);
}

is_done :: (coroutine : *Coroutine) -> bool
{
    return coroutine.done;
}



#scope_file

the_coroutine_code :: no_inline (coroutine : *Coroutine, jai_context : *Context) #c_call
{
    //
    // @@NOTE: When jmp-ing to here from the trampoline I was getting different behaviour with and
    // without optimizations at the time of writing. Without optimizations, the stack would get here
    // correctly aligned, but with optimizations on, the stack would get misaligned at the beginning
    // of this procedure because it counted on 8 bytes to be pushed to the stack by the call instruction
    // to this (which doesn't happen because we jmp here instead).
    //
    // Aligning the stack to 16 bytes by hand here fixes the issue on all the configurations currently
    // available (x64/llvm, various optimization levels, and Win32/Linux/MacOS). 
    //
    //                                                     - Ruben Osorio, 04/01/2023
    //
    #if ASSEMBLE 
    {
        #bytes BYTES;
        #run print_bytes_array(BYTES);
        BYTES :: #run x64_to_bytes(#string DONE
            and rsp, -16 # Aligning the stack to 16 bytes
        DONE);
    }
    else
    {
        #bytes u8.[0x48, 0x83, 0xe4, 0xf0];
    }
    push_context jai_context { coroutine.procedure(); }
    coroutine.done = true;
    switch_context(from = *coroutine.main_context, to = *coroutine.back_context, jai_context);
}

switch_context :: no_inline (from : *Coroutine_Context, to : *Coroutine_Context, jai_context : *Context) #c_call
{
    //
    // @@NOTE: It's important that this is a no_inline procedure as well. By not being inlined 
    // (and the platform_switch_context below), the calling code needs to take into account that all
    // the volatile registers (and state in general) might be gone by the time we return from this, which
    // means that on our coroutine contexts we only have to store the non-volatile stuff for that given platform.
    //
    // @@NOTE: This needs to be a #c_call (or possibly a #no_context) so we don't push stack traces.
    // Otherwise we'd be pushing the stack trace of switch_context when doing the call AFTER we
    // switched the context.stack_trace pointer.
    //
    #if _STACK_TRACE
    {
        from.stack_trace = jai_context.stack_trace;
        jai_context.stack_trace = to.stack_trace;
    }
    platform_switch_context(from, to);
}

#if OS == .WINDOWS
{
    Windows :: #import "Windows";

    Coroutine_Context :: struct
    {
        // Instruction Pointer and Non-volatile registers
        rip, rsp, rbp, rbx, r12, r13, r14, r15, rdi, rsi : u64;
        xmm6, xmm7, xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15 : XMM_Register;
        XMM_Register :: union
        {
            f32s : [4]float32;
            u32s : [4]u32;
            f64s : [2]float64;
            u64s : [2]u64;
        };
        #assert(size_of(XMM_Register) == 16);

        // Win32's Thread Information Block stuff (https://en.wikipedia.org/wiki/Win32_Thread_Information_Block)
        stack_base    : u64;
        stack_limit   : u64;
        dealloc_stack : u64;
        fiber_storage : u64;

        // Some extra FP math stuff
        MXCSR : u32 = 0x1f80;
        x87_fpu_control_word : u16 = 0x27f;

        // Jai's stack trace node
        #if _STACK_TRACE stack_trace : *Stack_Trace_Node = null;
    }

    platform_init :: (coroutine : *Coroutine, requested_stack_size : int)
    {
        // Allocate memory for the stack and set up a guard page at the beginning and end of it
        siSysInfo : Windows.SYSTEM_INFO;
        Windows.GetNativeSystemInfo(*siSysInfo);
        page_size : int = ifx siSysInfo.dwPageSize > 16 then siSysInfo.dwPageSize else 16;
        coroutine.stack_allocation.count = (((requested_stack_size + page_size - 1) / page_size) * page_size) + (ifx GUARD_PAGES then (2 * page_size) else 0);
        coroutine.stack_allocation.data = Windows.VirtualAlloc(null, cast(u64) coroutine.stack_allocation.count, Windows.MEM_RESERVE | Windows.MEM_COMMIT, Windows.PAGE_READWRITE);
        assert(coroutine.stack_allocation.data != null);
        #if GUARD_PAGES 
        {
            dummy : u32 = 0;
            protect_result_bottom_page := Windows.VirtualProtect(coroutine.stack_allocation.data,                                                cast(u64)page_size, Windows.PAGE_GUARD | Windows.PAGE_READWRITE, *dummy);
            protect_result_top_page    := Windows.VirtualProtect(coroutine.stack_allocation.data + coroutine.stack_allocation.count - page_size, cast(u64)page_size, Windows.PAGE_GUARD | Windows.PAGE_READWRITE, *dummy);
            assert(protect_result_bottom_page != 0);
            assert(protect_result_top_page    != 0);
        }

        // Put the stack in between the two guard pages 
        stack_bottom := coroutine.stack_allocation.data                                    + (ifx GUARD_PAGES then page_size else 0);
        stack_top    := coroutine.stack_allocation.data + coroutine.stack_allocation.count - (ifx GUARD_PAGES then page_size else 0);
        stack_bottom = (stack_bottom + 15) & ~15;
        stack_top    = (stack_top    + 15) & ~15;
        
        // Setup the initial state of the registers in the coroutine context
        coroutine.main_context.rip = cast(u64)cast(*void)(trampoline);         // Address we're going to jump to in the first execution
        coroutine.main_context.rsp = cast(u64)(stack_top);                     // Stack pointer
        coroutine.main_context.r12 = cast(u64)cast(*void)(the_coroutine_code); // Address the trampoline will jump to
        coroutine.main_context.r13 = cast(u64)(coroutine);                     // The pointer to the coroutine data
        coroutine.main_context.r14 = cast(u64)(*context);                      // The pointer to the current Jai context

        // Setup the initial state of Window's TIB or Thread Information Block stuff: https://en.wikipedia.org/wiki/Win32_Thread_Information_Block
        coroutine.main_context.stack_base    = cast(u64)stack_top;
        coroutine.main_context.stack_limit   = cast(u64)stack_bottom;
        coroutine.main_context.dealloc_stack = cast(u64)coroutine.stack_allocation.data;
        coroutine.main_context.fiber_storage = cast(u64)0; // Documentation is non-existant but people leave this as zero: https://github.com/boostorg/context/blob/develop/src/asm/make_x86_64_ms_pe_masm.asm 

        // Setup the initial state of some of the floating point math control registers
        {
            mxcsr_pointer                := *coroutine.main_context.MXCSR;
            x87_fpu_control_word_pointer := *coroutine.main_context.x87_fpu_control_word;
            #asm
            {
                stmxcsr [mxcsr_pointer];
                // I really wanted to do just: fnstcw [x87_fpu_control_word_pointer];
                // but we don't have that instruction, so pinning to a register and doing
                // it with a #bytes:
                mov r10 : gpr === 10, x87_fpu_control_word_pointer;
            }
            #if ASSEMBLE 
            {
                #bytes BYTES;
                #run print_bytes_array(BYTES);
                BYTES :: #run x64_to_bytes(#string DONE
                    fnstcw [r10]
                DONE);
            }
            else
            {
                #bytes u8.[0x41, 0xd9, 0x3a];
            }
        }

        // Procedure to jump to on the first run of the coroutine
        trampoline :: no_inline () #c_call
        {
            #if ASSEMBLE 
            {
                #bytes BYTES;
                #run print_bytes_array(BYTES);
                BYTES :: #run x64_to_bytes(#string DONE
                    mov rcx, r13   # *Coroutine
                    mov rdx, r14   # *Context
                    jmp r12        # jumping to the_coroutine_code(*Coroutine, *Context)
                DONE);
            }
            else
            {
                #bytes u8.[0x4c, 0x89, 0xe9, 0x4c, 0x89, 0xf2, 0x41, 0xff, 0xe4];
            }
        }
    }

    platform_deinit :: (coroutine : *Coroutine)
    {
        Windows.VirtualFree(coroutine.stack_allocation.data, 0, Windows.MEM_RELEASE);
    }

    platform_switch_context :: no_inline (from : *Coroutine_Context, to : *Coroutine_Context) #c_call
    {
        #asm
        {
            mov rcx: gpr === c, from;
            mov rdx: gpr === d, to;
        }
        #if ASSEMBLE 
        {
            #bytes BYTES;
            #run print_bytes_array(BYTES);
            BYTES :: #run x64_to_bytes(#string DONE
                # Compute the return address, [rip+offset] points to the instruction after the last jmp of this block
                lea rax,[rip+0x158] # IMPORTANT!! Update this offset if the assembly changes!!

                # Store to the "from" context

                    # Non-Volatile Registers 
                    mov  [rcx+0x00],rax
                    mov  [rcx+0x08],rsp
                    mov  [rcx+0x10],rbp
                    mov  [rcx+0x18],rbx
                    mov  [rcx+0x20],r12
                    mov  [rcx+0x28],r13
                    mov  [rcx+0x30],r14
                    mov  [rcx+0x38],r15
                    mov  [rcx+0x40],rdi
                    mov  [rcx+0x48],rsi
                    movaps [rcx+0x50],xmm6
                    movaps [rcx+0x60],xmm7
                    movaps [rcx+0x70],xmm8
                    movaps [rcx+0x80],xmm9
                    movaps [rcx+0x90],xmm10
                    movaps [rcx+0xa0],xmm11
                    movaps [rcx+0xb0],xmm12
                    movaps [rcx+0xc0],xmm13
                    movaps [rcx+0xd0],xmm14
                    movaps [rcx+0xe0],xmm15

                    # Get the address of the Thread Information Block
                    mov r10, gs:0x30

                    # Stack Base
                    mov rax, [r10+0x8]
                    mov [rcx+0xf0],rax

                    # Stack Limit
                    mov rax, [r10+0x10]
                    mov [rcx+0xf8],rax

                    # Deallocation Stack
                    mov rax, [r10+0x1478]
                    mov [rcx+0x100],rax

                    # Fiber Storage
                    mov rax, [r10+0x20]
                    mov [rcx+0x108],rax

                    # MXCSR (SSE Status/Control Register)
                    stmxcsr [rcx+0x110]

                    # x87 FPU Control Word
                    fnstcw [rcx+0x114]

                # Load from the "to" context 

                    # x87 FPU Control Word
                    fldcw [rdx+0x114]

                    # MXCSR
                    ldmxcsr [rdx+0x110]

                    # Fiber Storage
                    mov rax, [rdx+0x108]
                    mov [r10+0x20],rax

                    # Deallocation Stack
                    mov rax, [rdx+0x100]
                    mov [r10+0x1478],rax

                    # Stack Limit
                    mov rax, [rdx+0xf8]
                    mov [r10+0x10],rax

                    # Stack Base
                    mov rax, [rdx+0xf0]
                    mov [r10+0x8],rax

                    # Non-Volatile Registers 
                    movaps xmm15, [rdx+0xe0]
                    movaps xmm14, [rdx+0xd0]
                    movaps xmm13, [rdx+0xc0]
                    movaps xmm12, [rdx+0xb0]
                    movaps xmm11, [rdx+0xa0]
                    movaps xmm10, [rdx+0x90]
                    movaps xmm9,  [rdx+0x80]
                    movaps xmm8,  [rdx+0x70]
                    movaps xmm7,  [rdx+0x60]
                    movaps xmm6,  [rdx+0x50]
                    mov  rsi,   [rdx+0x48]
                    mov  rdi,   [rdx+0x40]
                    mov  r15,   [rdx+0x38]
                    mov  r14,   [rdx+0x30]
                    mov  r13,   [rdx+0x28]
                    mov  r12,   [rdx+0x20]
                    mov  rbx,   [rdx+0x18]
                    mov  rbp,   [rdx+0x10]
                    mov  rsp,   [rdx+0x8]

                # Might as well JMP
                jmp [rdx]

                # Leaving Jai to do the final ret, because it might need to do stuff
                # like popping the shadow space it allocated at the beginning, popping rbp, etc. 
            DONE);
        }
        else
        {
            #bytes u8.[0x48, 0x8d, 0x05, 0x58, 0x01, 0x00, 0x00, 0x48,
                       0x89, 0x01, 0x48, 0x89, 0x61, 0x08, 0x48, 0x89,
                       0x69, 0x10, 0x48, 0x89, 0x59, 0x18, 0x4c, 0x89,
                       0x61, 0x20, 0x4c, 0x89, 0x69, 0x28, 0x4c, 0x89,
                       0x71, 0x30, 0x4c, 0x89, 0x79, 0x38, 0x48, 0x89,
                       0x79, 0x40, 0x48, 0x89, 0x71, 0x48, 0x0f, 0x29,
                       0x71, 0x50, 0x0f, 0x29, 0x79, 0x60, 0x44, 0x0f,
                       0x29, 0x41, 0x70, 0x44, 0x0f, 0x29, 0x89, 0x80,
                       0x00, 0x00, 0x00, 0x44, 0x0f, 0x29, 0x91, 0x90,
                       0x00, 0x00, 0x00, 0x44, 0x0f, 0x29, 0x99, 0xa0,
                       0x00, 0x00, 0x00, 0x44, 0x0f, 0x29, 0xa1, 0xb0,
                       0x00, 0x00, 0x00, 0x44, 0x0f, 0x29, 0xa9, 0xc0,
                       0x00, 0x00, 0x00, 0x44, 0x0f, 0x29, 0xb1, 0xd0,
                       0x00, 0x00, 0x00, 0x44, 0x0f, 0x29, 0xb9, 0xe0,
                       0x00, 0x00, 0x00, 0x65, 0x4c, 0x8b, 0x14, 0x25,
                       0x30, 0x00, 0x00, 0x00, 0x49, 0x8b, 0x42, 0x08,
                       0x48, 0x89, 0x81, 0xf0, 0x00, 0x00, 0x00, 0x49,
                       0x8b, 0x42, 0x10, 0x48, 0x89, 0x81, 0xf8, 0x00,
                       0x00, 0x00, 0x49, 0x8b, 0x82, 0x78, 0x14, 0x00,
                       0x00, 0x48, 0x89, 0x81, 0x00, 0x01, 0x00, 0x00,
                       0x49, 0x8b, 0x42, 0x20, 0x48, 0x89, 0x81, 0x08,
                       0x01, 0x00, 0x00, 0x0f, 0xae, 0x99, 0x10, 0x01,
                       0x00, 0x00, 0xd9, 0xb9, 0x14, 0x01, 0x00, 0x00,
                       0xd9, 0xaa, 0x14, 0x01, 0x00, 0x00, 0x0f, 0xae,
                       0x92, 0x10, 0x01, 0x00, 0x00, 0x48, 0x8b, 0x82,
                       0x08, 0x01, 0x00, 0x00, 0x49, 0x89, 0x42, 0x20,
                       0x48, 0x8b, 0x82, 0x00, 0x01, 0x00, 0x00, 0x49,
                       0x89, 0x82, 0x78, 0x14, 0x00, 0x00, 0x48, 0x8b,
                       0x82, 0xf8, 0x00, 0x00, 0x00, 0x49, 0x89, 0x42,
                       0x10, 0x48, 0x8b, 0x82, 0xf0, 0x00, 0x00, 0x00,
                       0x49, 0x89, 0x42, 0x08, 0x44, 0x0f, 0x28, 0xba,
                       0xe0, 0x00, 0x00, 0x00, 0x44, 0x0f, 0x28, 0xb2,
                       0xd0, 0x00, 0x00, 0x00, 0x44, 0x0f, 0x28, 0xaa,
                       0xc0, 0x00, 0x00, 0x00, 0x44, 0x0f, 0x28, 0xa2,
                       0xb0, 0x00, 0x00, 0x00, 0x44, 0x0f, 0x28, 0x9a,
                       0xa0, 0x00, 0x00, 0x00, 0x44, 0x0f, 0x28, 0x92,
                       0x90, 0x00, 0x00, 0x00, 0x44, 0x0f, 0x28, 0x8a,
                       0x80, 0x00, 0x00, 0x00, 0x44, 0x0f, 0x28, 0x42,
                       0x70, 0x0f, 0x28, 0x7a, 0x60, 0x0f, 0x28, 0x72,
                       0x50, 0x48, 0x8b, 0x72, 0x48, 0x48, 0x8b, 0x7a,
                       0x40, 0x4c, 0x8b, 0x7a, 0x38, 0x4c, 0x8b, 0x72,
                       0x30, 0x4c, 0x8b, 0x6a, 0x28, 0x4c, 0x8b, 0x62,
                       0x20, 0x48, 0x8b, 0x5a, 0x18, 0x48, 0x8b, 0x6a,
                       0x10, 0x48, 0x8b, 0x62, 0x08, 0xff, 0x22, ];
        }
    }

}
else #if OS == .MACOS || OS == .LINUX
{
    POSIX :: #import "POSIX";

    Coroutine_Context :: struct
    {
        // Instruction Pointer and Non-volatile registers
        rip, rsp, rbp, rbx, r12, r13, r14, r15 : u64;

        // Some extra FP math stuff
        MXCSR : u32 = 0x1f80;
        x87_fpu_control_word : u16 = 0x27f;

        // Jai's stack trace node
        #if _STACK_TRACE stack_trace : *Stack_Trace_Node = null;
    }

    platform_init :: (coroutine : *Coroutine, requested_stack_size : int)
    {
        // Allocate memory for the stack and set up a guard page at the beginning and end of it
        posix_page_size : int = POSIX.sysconf(POSIX._SC_PAGE_SIZE);
        page_size := ifx posix_page_size > 16 then posix_page_size else 16;
        coroutine.stack_allocation.count = (((requested_stack_size + page_size - 1) / page_size) * page_size) + (ifx GUARD_PAGES then (2 * page_size) else 0);
        MAP_STACK :: 0x20000;
        coroutine.stack_allocation.data = POSIX.mmap(null, cast(u64) coroutine.stack_allocation.count, prot = POSIX.PROT_READ | POSIX.PROT_WRITE, flags = POSIX.MAP_PRIVATE | POSIX.MAP_ANONYMOUS | MAP_STACK, fildes = -1, offset = 0);
        assert(coroutine.stack_allocation.data != null && coroutine.stack_allocation.data != cast(*void)-1);
        #if GUARD_PAGES
        {
            protect_result_bottom_page := POSIX.mprotect(coroutine.stack_allocation.data,                                                cast(u64)page_size, POSIX.PROT_NONE);
            protect_result_top_page    := POSIX.mprotect(coroutine.stack_allocation.data + coroutine.stack_allocation.count - page_size, cast(u64)page_size, POSIX.PROT_NONE);
            assert(protect_result_bottom_page == 0);
            assert(protect_result_top_page    == 0);
        }

        // Put the stack in between the two guard pages 
        stack_bottom := coroutine.stack_allocation.data                                    + (ifx GUARD_PAGES then page_size else 0);
        stack_top    := coroutine.stack_allocation.data + coroutine.stack_allocation.count - (ifx GUARD_PAGES then page_size else 0);
        stack_bottom = (stack_bottom + 15) & ~15;
        stack_top    = (stack_top    + 15) & ~15;

        // Setup the initial state of the registers in the coroutine context
        coroutine.main_context.rip = cast(u64)cast(*void)(trampoline);         // Address we're going to jump to in the first execution
        coroutine.main_context.rsp = cast(u64)(stack_top);                     // Stack pointer
        coroutine.main_context.r12 = cast(u64)cast(*void)(the_coroutine_code); // Address the trampoline will jump to
        coroutine.main_context.r13 = cast(u64)(coroutine);                     // Coroutine procedure that start will call
        coroutine.main_context.r14 = cast(u64)(*context);                      // The pointer to the current Jai context

        // Setup the initial state of some of the floating point math control registers
        {
            mxcsr_pointer                := *coroutine.main_context.MXCSR;
            x87_fpu_control_word_pointer := *coroutine.main_context.x87_fpu_control_word;
            #asm
            {
                stmxcsr [mxcsr_pointer];
                // I really wanted to do just: fnstcw [x87_fpu_control_word_pointer];
                // but we don't have that instruction, so pinning to a register and doing
                // it with a #bytes:
                mov r10 : gpr === 10, x87_fpu_control_word_pointer;
            }
            #if ASSEMBLE 
            {
                #bytes BYTES;
                #run print_bytes_array(BYTES);
                BYTES :: #run x64_to_bytes(#string DONE
                    fnstcw [r10]
                DONE);
            }
            else
            {
                #bytes u8.[0x41, 0xd9, 0x3a];
            }
        }

        // Procedure to jump to on the first run of the coroutine
        trampoline :: no_inline () #c_call
        {
            #if ASSEMBLE 
            {
                #bytes BYTES;
                #run print_bytes_array(BYTES);
                BYTES :: #run x64_to_bytes(#string DONE
                    mov rdi, r13   # *Coroutine
                    mov rsi, r14   # *Context
                    jmp r12        # jumping to the_coroutine_code(*Coroutine, *Context)
                DONE);
            }
            else
            {
                #bytes u8.[0x4c, 0x89, 0xef, 0x4c, 0x89, 0xf6, 0x41, 0xff, 0xe4];
            }
        }
    }

    platform_deinit :: (coroutine : *Coroutine)
    {
        unmap_result := POSIX.munmap(coroutine.stack_allocation.data, xx coroutine.stack_allocation.count);
        assert(unmap_result == 0);
    }

    platform_switch_context :: no_inline (from : *Coroutine_Context, to : *Coroutine_Context) #c_call
    {
        #asm
        {
            mov rdi: gpr === di, from;
            mov rsi: gpr === si, to;
        }
        #if ASSEMBLE 
        {
            #bytes BYTES;
            #run print_bytes_array(BYTES);
            BYTES :: #run x64_to_bytes(#string DONE
                # Compute the return address, rip+offset points to the instruction after the last jmp of this block
                lea    rax,[rip+0x4B]

                # Store to the "from" context
                mov  [rdi+0x00],rax
                mov  [rdi+0x08],rsp
                mov  [rdi+0x10],rbp
                mov  [rdi+0x18],rbx
                mov  [rdi+0x20],r12
                mov  [rdi+0x28],r13
                mov  [rdi+0x30],r14
                mov  [rdi+0x38],r15
                stmxcsr [rdi+0x40]
                fnstcw  [rdi+0x44]

                # Load from the "to" context
                fldcw       [rsi+0x44]
                ldmxcsr     [rsi+0x40]
                mov  r15,   [rsi+0x38]
                mov  r14,   [rsi+0x30]
                mov  r13,   [rsi+0x28]
                mov  r12,   [rsi+0x20]
                mov  rbx,   [rsi+0x18]
                mov  rbp,   [rsi+0x10]
                mov  rsp,   [rsi+0x8]

                # Might as well JMP
                jmp [rsi]

                # Leaving Jai to do the final ret, because it might need to do stuff
                # like popping the shadow space it allocated at the beginning, popping rbp, etc. 
            DONE);
        }
        else
        {
            #bytes u8.[0x48, 0x8d, 0x05, 0x4b, 0x00, 0x00, 0x00, 0x48,
                       0x89, 0x07, 0x48, 0x89, 0x67, 0x08, 0x48, 0x89,
                       0x6f, 0x10, 0x48, 0x89, 0x5f, 0x18, 0x4c, 0x89,
                       0x67, 0x20, 0x4c, 0x89, 0x6f, 0x28, 0x4c, 0x89,
                       0x77, 0x30, 0x4c, 0x89, 0x7f, 0x38, 0x0f, 0xae,
                       0x5f, 0x40, 0xd9, 0x7f, 0x44, 0xd9, 0x6e, 0x44,
                       0x0f, 0xae, 0x56, 0x40, 0x4c, 0x8b, 0x7e, 0x38,
                       0x4c, 0x8b, 0x76, 0x30, 0x4c, 0x8b, 0x6e, 0x28,
                       0x4c, 0x8b, 0x66, 0x20, 0x48, 0x8b, 0x5e, 0x18,
                       0x48, 0x8b, 0x6e, 0x10, 0x48, 0x8b, 0x66, 0x08,
                       0xff, 0x26, ];
        }
    }
}
else
{
    #assert(false);
}



/*Avengers?*/ ASSEMBLE :: false;
#if ASSEMBLE
{
    #import "Basic";
    #import "File";
    #import "Process";
    #import "executable_formats";
    #import "Atomics";

    counter := 0;
    x64_to_bytes :: (x64_code : string) -> []u8
    {
        //
        // @@NOTE: We compile the assembly string to an object file:
        //
        // clang -c -mllvm --x86-asm-syntax=intel -o assembly.o assembly.s
        //
        // Then read the COFF file and extract the first executable code section, not
        // rocket surgery but does the job for a one off case.
        //
        // Obviously this won't work if you don't have clang available, but the vast majority
        // of people shouldn't need this. In fact, You'd only really need it if you're going to
        // modify the hand-written x64 assembly. Even on those cases and even if you can't have
        // clang available, it should be easy to switch for a different command, of maybe with
        // an assembler module if it exists!
        //
        // And even in that case, if the modification is a one-time thing you could probably do
        // with assembling it by hand and copying the byte array. There's even tools online you
        // can use for this such as:
        //
        // - https://defuse.ca/online-x86-assembler.htm
        //
        //                                           - Ruben Osorio, 04/01/2023
        // 

        index := atomic_add(*counter, 1);
        source_filename := tprint("_temp_assembly_%.s", index);
        object_filename := tprint("_temp_assembly_%.o", index);

        write_source_success := write_entire_file(source_filename, x64_code);
        assert(write_source_success);
        defer file_delete(source_filename);

        compile_result, output_string, error_string := run_command("clang", "-c", "-mllvm", "--x86-asm-syntax=intel", "-o", object_filename, source_filename);
        defer file_delete(object_filename);
        if !(compile_result.type == .EXITED && compile_result.exit_code == 0)    
        {
            log_error("Couldn't build assembly code!!\n[ERROR]: % % \n\n\n", output_string, error_string);
            assert(false);
        }

        temporary_context := context;
        temporary_context.allocator = temporary_allocator;
        push_context temporary_context
        {
            file_contents := read_entire_file(object_filename);

            if is_coff(file_contents)
            {
                success, coff := parse_coff(file_contents);
                assert(success);
                for coff.section_headers
                {
                    if (it.characteristics & .CNT_CODE) != 0 
                    {
                        bytes := get_section_data(coff, it_index);
                        return bytes;
                    }
                }
            }
            else if is_elf(file_contents)
            {
                success, elf := parse_elf(file_contents);
                assert(success);
                for elf.sections
                {
                    if it.type == .PROGBITS && (it.flags & .EXECINSTR) != 0
                    {
                        bytes : []u8;
                        bytes.data  = file_contents.data + it.offset;
                        bytes.count = xx it.size;
                        return bytes;
                    }
                }

            }
            assert(false);
            return .[];
        }
    }

    print_bytes_array :: (bytes : []u8)
    {
        print("\n\n\n#bytes u8.[");
        for bytes
        {
            print("0x%, ", formatInt(it, minimum_digits = 2, base = 16));
            if (it_index % 8) == 7 print("\n           ");
        }
        print("];\n\n\n");
    }
}


