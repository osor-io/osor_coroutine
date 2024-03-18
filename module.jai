


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
//                                            - Ruben Osorio, 04/01/2023
//



#module_parameters(ASSERT := true, GUARD_PAGES := true, DEFAULT_STACK_SIZE := 64 * 1024, TEMPORARY_STORAGE_SIZE := 4 * 1024, CHECK_STACK_USAGE := false);
#if ASSERT #import "Basic";
else assert :: (arg: bool, message := "", args: .. Any, loc := #caller_location) #expand {};



Coroutine :: struct (Procedure_Type : Type)
{
    main_context : Coroutine_Context #align 16;
    back_context : Coroutine_Context #align 16;

    pointer_to_context : *Context;

    stack : []u8;
    stack_allocation : []u8;

    procedure : Procedure_Type;
    #assert(type_info(Procedure_Type).type == .PROCEDURE);
    #assert(type_info(Procedure_Type).return_types.count == 0);
    Packed_Arguments :: #run generate_packed_arguments(Procedure_Type);
    #assert(type_info(Procedure_Type).argument_types.count == type_info(Packed_Arguments).members.count-1);
}

init :: (coroutine : *Coroutine,
         procedure : type_of(coroutine.procedure),
         $arguments : ..Code,
         stack : []u8 = .[],
         requested_stack_size := DEFAULT_STACK_SIZE,
         loc := #caller_location) #expand
{
    #run
    {
        if arguments.count != type_info(coroutine.Procedure_Type).argument_types.count
        {
            compiler_report(tprint("Trying to initialize a coroutine that takes % arguments but % were provided, the procedure type is %", type_info(coroutine.Procedure_Type).argument_types.count, arguments.count, coroutine.Procedure_Type), loc);
        }
    }

    assert(!is_initialized(coroutine));
    coroutine.* = .{}; 
    coroutine.procedure = procedure;

    #insert -> string
    {
        builder : String_Builder;
        append(*builder, "packed_arguments := coroutine.Packed_Arguments.{");
        for arguments print(*builder, "#insert arguments[%1],\n", it_index);
        append(*builder, "*context\n");
        append(*builder, "};");
        return builder_to_string(*builder);
    }

    platform_init(coroutine, *packed_arguments, stack, requested_stack_size);

    #if CHECK_STACK_USAGE then memset(coroutine.stack.data, 0xC0, coroutine.stack.count);

    //
    // @@NOTE: Switching to the coroutine once here so it's able to finish it's internal
    // setup. This includes stuff like reading the packed arguments and keeping them
    // on its stack. You can see this happening at the beginning of the_coroutine_code(...)
    //
    // This does **NOT** mean that when the user calls init(...) the coroutine starts running!
    //
    // See the first switch_context(...) call in the_coroutine_code, that's after all the setup has finished and
    // before the user code has started executing.
    //
    switch_context(from = *coroutine.back_context, to = *coroutine.main_context);
}

deinit :: (coroutine : *Coroutine)
{
    if is_initialized(coroutine)
    {
        #if ASSERT && CHECK_STACK_USAGE
        {
            stack_overflow := check_stack_usage(coroutine);
            assert(!stack_overflow, "Potential stack overflow! All the bytes on the stack were modified, which hints that it might have grown above it's allocated size");
        }
        platform_deinit(coroutine);
        coroutine.* = .{}; 
        assert(!is_initialized(coroutine));
    }
}

run :: (coroutine : *Coroutine, deinit_when_is_done := true)
{
    assert(is_initialized(coroutine));
    assert(!is_done(coroutine));
    coroutine.pointer_to_context.current_coroutine = cast(*void)coroutine;
    coroutine.pointer_to_context.thread_index = context.thread_index;
    switch_context(from = *coroutine.back_context, to = *coroutine.main_context);
    if deinit_when_is_done && is_done(coroutine) then deinit(coroutine);
}

yield :: ()
{
    assert(context.current_coroutine != null);
    switch_context(from = *context.current_coroutine.main_context, to = *context.current_coroutine.back_context);
}

is_done :: (coroutine : Coroutine) -> bool
{
    return coroutine.pointer_to_context == null;
}

is_initialized :: (coroutine : Coroutine) -> bool
{
    return coroutine.procedure != null;
}

#if CHECK_STACK_USAGE
{
    check_stack_usage :: (coroutine : Coroutine) -> overflow : bool, touched_stack_bytes : int, percentage_of_stack : float
    {
        //
        // @@NOTE: When we enable stack checking we're setting the whole stack
        // to a known byte value. The coroutine code will then use the stack, potentially
        // touching and changing the data in it. Here we can traverse this data
        // and see where is the deepest byte in the stack that doesn't match our
        // known byte value. This means that the user code has written to it and that
        // therefore the stack must have been pushed at least that deep.
        //
        // It's not an exact watermark of stack usage, but it can give us an estimation
        // of how much of the stack has been used by the coroutine code. And if we see
        // that the whole stack has been touched, it could be hinting that a stack overflow
        // has happened. If we're running with GUARD_PAGES then we migth have caught it earlier
        // but if the user has provided their own stack memory this could help (since we can't
        // put guard pages on that).
        //
        //                                   - Ruben Osorio, 07/03/2024
        //
        //
        last_untouched_byte := -1;
        for coroutine.stack
        {
            if it != 0xC0 then break;
            last_untouched_byte = it_index;
        }
        touched_bytes := coroutine.stack.count - last_untouched_byte;
        return last_untouched_byte < 0, touched_bytes, (cast(float)touched_bytes)/(cast(float)coroutine.stack.count);
    }
}



#scope_file



#import "Compiler";



generate_packed_arguments :: ($procedure_type : Type) -> Type
{
    ARGUMENT_TYPE_COUNT :: #run type_info(procedure_type).argument_types.count;
    ARGUMENT_TYPES :: #run () -> [ARGUMENT_TYPE_COUNT]Type
    {
        types : [ARGUMENT_TYPE_COUNT]Type;
        for type_info(procedure_type).argument_types types[it_index] = get_type(it);
        return types;
    }();
    #insert -> string
    {
        builder : String_Builder;
        append(*builder, "Packed_Arguments :: struct {");
        for ARGUMENT_TYPES print(*builder, "argument_%1 : ARGUMENT_TYPES[%1];", it_index);
        append(*builder, "init_context : *Context;");
        append(*builder, "}\n");
        return builder_to_string(*builder);
    }
    return Packed_Arguments;
}

//
// @@NOTE: We can use a coroutine that points to a generic procedure
// for most things, because the only variable data it has is really the
// Procedure_Type which we only really use at the beginning when starting
// to execute the_coroutine_code for the first time.
//
// For switching contexts or other purposes, we don't need
// that type information, so this can be used directly.
//
#add_context current_coroutine : *Coroutine(#type ()) = null;
the_coroutine_code :: no_inline (coroutine : *Coroutine, arguments : *coroutine.Packed_Arguments) #c_call
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

    //
    // @@NOTE: Setting up a buffer for temporary storage, it will live on the stack of the coroutine
    // itself so in a way the user can think of it as an "alloca" in other languages. Any allocations
    // that overflow this storage should go into extra pages, which should all get freed after the 
    // coroutine has returned via then reset_temporary_storage(...) below.
    //
    temporary_storage_buffer : [TEMPORARY_STORAGE_SIZE]u8;
    static_temporary_storage : Temporary_Storage;
    set_initial_data(*static_temporary_storage, temporary_storage_buffer.count, temporary_storage_buffer.data);

    //
    // @@NOTE: Instantiating a context on the stack that the coroutine will use.
    //
    // Some care is needed with what's in it, and some of the data, depending on what the user puts
    // in it as well, might be incorrect. Currently it's mostly a copy of the context that initialized
    // the coroutine, with some other members set up needed for the coroutine to run.
    //
    // Things like the thread_index, we can keep up-to-date by setting them through a pointer
    // to this context that the coroutine keeps in Coroutine.pointer_to_context.
    //
    // In essence, this is very similar to how the context for a new thread would work, where it starts
    // with a copy of a known context but can freely change from there onwards, so the user can look at
    // it that way. In fact, at the time of writing, this happens to be pretty much the same as what the
    // official threading module does.
    //
    //                                            - Ruben Osorio, 09/03/2024
    //
    new_context := arguments.init_context.*; 
    new_context.temporary_storage = *static_temporary_storage;
    new_context.thread_index = ~cast(type_of(new_context.thread_index))0;
    new_context.current_coroutine = cast(*void)coroutine;
    #if _STACK_TRACE
    {
        stack_trace_sentinel : Stack_Trace_Node;
        new_context.stack_trace = *stack_trace_sentinel;
    }

    push_context new_context
    {
        coroutine.pointer_to_context = *context;
        arguments_copy := arguments.*;
        procedure := coroutine.procedure;
        switch_context(from = *context.current_coroutine.main_context, to = *context.current_coroutine.back_context);

        //
        // @@NOTE: From this point onward, we cannot use the *Couroutine given to us as a parameter
        // because the user might do a copy of the coroutine and call run on that one instead, therefore
        // invalidating the memory that the original coroutine pointer we have head points at. 
        //
        // To get around that issue, we can refer to the true coroutine we're running via the one that's
        // in the context, because we can update that one as we call run(...).
        //

        #insert -> string
        {
            builder : String_Builder;
            append(*builder, "no_inline procedure(");
            for 0..type_info(type_of(arguments_copy)).members.count-2 // -2 cause it has init_context
            {
                print(*builder, "arguments_copy.argument_%,", it);
            }
            append(*builder, ");");
            return builder_to_string(*builder);
        };

        reset_temporary_storage();
        assert(static_temporary_storage.overflow_pages == null);
        #asm { mfence; lfence; }
        context.current_coroutine.pointer_to_context = null;
        switch_context(from = *context.current_coroutine.main_context, to = *context.current_coroutine.back_context);
    }
}

switch_context :: no_inline (from : *Coroutine_Context, to : *Coroutine_Context) #c_call
{
    //
    // @@NOTE: It's important that this is a no_inline procedure as well. By not being inlined 
    // (and the platform_switch_context below), the calling code needs to take into account that all
    // the volatile registers (and state in general) might be gone by the time we return from this, which
    // means that on our coroutine contexts we only have to store the non-volatile stuff for that given platform.
    //
    // @@NOTE: Adding a fences here to prevent the compiler from optimizing ordering around context switches,
    // although this might already be happening with this being a non-inlined procedure call. Also gives us
    // serializing behaviour when jumping to/from the coroutine code which may be relevant in multithreading
    // environments. The behaviour of these is well explained in here:
    //
    //  - https://hadibrais.wordpress.com/2018/05/14/the-significance-of-the-x86-lfence-instruction/
    //
    #asm { mfence; lfence; }
    platform_switch_context(from, to);
    #asm { mfence; lfence; }
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
    }

    platform_init :: (coroutine : *Coroutine, arguments : *coroutine.Packed_Arguments, user_provided_stack : []u8, requested_stack_size : int)
    {
        // Setup the stack's top (highest address) and bottom (lowest address)
        stack_bottom : *u8;
        stack_top    : *u8;
        if user_provided_stack
        {
            stack_bottom = user_provided_stack.data;
            stack_top    = user_provided_stack.data + user_provided_stack.count;
        }
        else
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
            stack_bottom = coroutine.stack_allocation.data                                    + (ifx GUARD_PAGES then page_size else 0);
            stack_top    = coroutine.stack_allocation.data + coroutine.stack_allocation.count - (ifx GUARD_PAGES then page_size else 0);
        }
        stack_bottom = (stack_bottom + 15) & ~15;
        stack_top = stack_top & ~15;
        coroutine.stack.data  = stack_bottom; 
        coroutine.stack.count = stack_top - stack_bottom; 

        // Setup the initial state of the registers in the coroutine context
        trampoline :: no_inline () #c_call // Procedure to jump to on the first run of the coroutine
        {
            #if ASSEMBLE 
            {
                #bytes BYTES;
                #run print_bytes_array(BYTES);
                BYTES :: #run x64_to_bytes(#string DONE
                    mov rcx, r13   # *Coroutine
                    mov rdx, r14   # *Coroutine.Packed_Arguments
                    jmp r12        # jumping to the_coroutine_code(*Coroutine, *Coroutine.Packed_Arguments)
                DONE);
            }
            else
            {
                #bytes u8.[0x4c, 0x89, 0xe9, 0x4c, 0x89, 0xf2, 0x41, 0xff, 0xe4];
            }
        }
        COROUTINE_CODE :: #procedure_of_call(the_coroutine_code(coroutine, arguments));
        coroutine.main_context.rip = cast(u64)cast(*void)(trampoline);     // Address we're going to jump to in the first execution
        coroutine.main_context.rsp = cast(u64)(stack_top);                 // Stack pointer
        coroutine.main_context.r12 = cast(u64)cast(*void)(COROUTINE_CODE); // Address the trampoline will jump to
        coroutine.main_context.r13 = cast(u64)(coroutine);                 // The pointer to the coroutine data
        coroutine.main_context.r14 = cast(u64)(arguments);                 // The pointer to the coroutine's arguments 

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
    }

    platform_deinit :: (coroutine : *Coroutine)
    {
        if coroutine.stack_allocation
        {
            Windows.VirtualFree(coroutine.stack_allocation.data, 0, Windows.MEM_RELEASE);
        }
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
    }

    platform_init :: (coroutine : *Coroutine, arguments : *coroutine.Packed_Arguments, requested_stack_size : int)
    {
        // Setup the stack's top (highest address) and bottom (lowest address)
        stack_bottom : *u8;
        stack_top    : *u8;
        if user_provided_stack
        {
            stack_bottom = user_provided_stack.data;
            stack_top    = user_provided_stack.data + user_provided_stack.count;
        }
        else
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
            stack_bottom = coroutine.stack_allocation.data                                    + (ifx GUARD_PAGES then page_size else 0);
            stack_top    = coroutine.stack_allocation.data + coroutine.stack_allocation.count - (ifx GUARD_PAGES then page_size else 0);
        }
        stack_bottom = (stack_bottom + 15) & ~15;
        stack_top = stack_top & ~15;
        coroutine.stack.data  = stack_bottom; 
        coroutine.stack.count = stack_top - stack_bottom; 

        // Setup the initial state of the registers in the coroutine context
        trampoline :: no_inline () #c_call // Procedure to jump to on the first run of the coroutine
        {
            #if ASSEMBLE 
            {
                #bytes BYTES;
                #run print_bytes_array(BYTES);
                BYTES :: #run x64_to_bytes(#string DONE
                    mov rdi, r13   # *Coroutine
                    mov rsi, r14   # *Coroutine.Packed_Arguments
                    jmp r12        # jumping to the_coroutine_code(*Coroutine, *Coroutine.Packed_Arguments)
                DONE);
            }
            else
            {
                #bytes u8.[0x4c, 0x89, 0xef, 0x4c, 0x89, 0xf6, 0x41, 0xff, 0xe4];
            }
        }
        COROUTINE_CODE :: #procedure_of_call(the_coroutine_code(coroutine, arguments));
        coroutine.main_context.rip = cast(u64)cast(*void)(trampoline);     // Address we're going to jump to in the first execution
        coroutine.main_context.rsp = cast(u64)(stack_top);                 // Stack pointer
        coroutine.main_context.r12 = cast(u64)cast(*void)(COROUTINE_CODE); // Address the trampoline will jump to
        coroutine.main_context.r13 = cast(u64)(coroutine);                 // The pointer to the coroutine data
        coroutine.main_context.r14 = cast(u64)(arguments);                 // The pointer to the coroutine's arguments 

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
    }

    platform_deinit :: (coroutine : *Coroutine)
    {
        if coroutine.stack_allocation
        {
            unmap_result := POSIX.munmap(coroutine.stack_allocation.data, xx coroutine.stack_allocation.count);
            assert(unmap_result == 0);
        }
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


