#import,dir "../osor_coroutine";
#import "Basic";
#import "Random";



main :: ()
{
    simple_coroutine();
    arguments_and_return_types();
    fibonacci_in_u64();
    roguelike_room();
    text_adventure_conversation();
    doing_allocations();
    custom_stack_memory();
}



simple_coroutine :: ()
{
    print_example_name("A simple coroutine call");

    //
    // A simple example where we call a coroutine and it executes until the yield() call, then
    // we call it again and it executes until the end. Just to get a test for things. More
    // details on what you can do with this on further examples.
    //
    the_coroutine_code :: ()
    {
        print("[Coroutine] Hello! The coroutine is just starting, I'm lazy so that's all I'm gonna do this time, coming back to the caller\n");
        yield(); // Here we return to the code that called run() and we continue from here on the next run() call
        print("[Coroutine] We have come back to the coroutine, It seems like I'm more than lazy, so I'm finishing now\n");
        return;
    }

    coroutine : Coroutine(Procedure_Type = type_of(the_coroutine_code));
    init(*coroutine, procedure = the_coroutine_code);
    defer deinit(*coroutine);

    print("[Caller] Running coroutine for the first time\n");
    run(*coroutine);
    print("[Caller] Running the coroutine again, is it done? %\n", is_done(*coroutine));
    run(*coroutine);
    print("[Caller] We ran the coroutine twice, and it has now finished, right? %\n", is_done(*coroutine));
}



arguments_and_return_types :: ()
{
    print_example_name("Testing arguments");

    the_coroutine_code :: (an_integer : int, a_float : *float)
    {
        a_float.* = cast(float)an_integer + 1.5;
        yield();
        a_float.* += 1.0;
    }

    //
    // Here we're passing in an integer as a parameter as well
    // as a pointer to a float that we can see how the coroutine
    // modifies from the outside.
    //
    // Note how here we pass in the procedure parameters after
    // the procedure we want to call.
    //
    // For simplicity, these coroutines don't support return
    // values, but you can pass in pointers to data to be modified
    // like we're doing here.
    //
    // Another feature that might not be obvious is that the parameters
    // still behave like normal parameters on a traditional procedure call
    // would, so you can do stuff like automatic casting as you can see
    // on the "xx 5.0" casted to the int that the coroutine takes.
    //
    coroutine : Coroutine(type_of(the_coroutine_code));
    a_float : float;
    init(*coroutine, the_coroutine_code, xx 5.0, *a_float);
    defer deinit(*coroutine);

    while !is_done(*coroutine)
    {
        run(*coroutine);
        print("Corroutine changed a_float to %\n", a_float);
    }
}



fibonacci_in_u64 :: ()
{
    print_example_name("All the fibonacci numbers until they overflow a u64");

    fibonacci :: (index : *int, number : *u64)
    {
        //
        // These two local variables will live on the coroutine's stack now (or in registers)
        // and even if we're going to go back to the caller every time we call yield(), their 
        // value will persist because the coroutine keeps its own stack separate and it restores
        // any non-volatile registers when switching.
        //
        // As proof of this, you can see how in between the yields, we still successfully keep track
        // of the last two fibonacci numbers to calculate the next one.
        //
        a : u64 = 0;
        b : u64 = 1;

        //
        // yield() means that we're returning the control to our caller. You can think of this kind
        // of like a return statement but one where next time we run() the coroutine we come back to exactly after this
        // point in the code, we don't come back to the beginning of the procedure.
        //
        // So right in this line, we'll jump to the while !is_done() loop in coroutine_example().
        //
        index.* = 0;
        number.* = a;
        yield();
        //
        // Then when coroutine_example() decides to call run() on us again, we jump back to exactly here, just
        // after the yield();
        //
        // This makes it so you can write code that shows a particular behaviour all in one place
        // and keeping the local variable state for you, but it can execute over many different calls, while leaving
        // time for other code to do their thing. For example, in a game situation, you could call a given coroutine
        // once per-frame, so it does one step of its update, then you come back to the game-loop and do the rest of 
        // your user input, update, rendering, etc.
        //

        for 1..100
        {
            if (a > 0xffff_ffff_ffff_ffff - b)
            {
                print("Apparently fibonacci index % overflows a u64! :D\n", it);

                index.* = -1;
                number.* = 0xffff_ffff_ffff_ffff;
                break;
            }
            else
            {
                sum := a + b;
                a = b;
                b = sum;

                index.* = it;
                number.* = a;
                yield();
            }
        }
        print("And we're done!\n");

        //
        // After the coroutine returns, we'll come back to the caller in a similar way to when you call
        // yield manually, the only difference being that this coroutine can't be resumed anymore since it
        // ran out of instructions to run! And from here onwards is_done(coroutine) will return true.
        //
    }

    index := -1;
    number : u64;

    //
    // This is an example where you use a coroutine to generate a list of values, giving
    // you one more every time the code gets called.
    //
    // This is sometimes called a "Generator" in the context of other languages, as you can
    // see it's easy to implement with coroutines as a building block.
    //
    coroutine : Coroutine(type_of(fibonacci));
    init(*coroutine, fibonacci, *index, *number);
    defer deinit(*coroutine);
    while !is_done(*coroutine)
    {
        run(*coroutine);
        if index >= 0 print("Fibonacci index % is %\n", index, number);
    }
}



roguelike_room :: ()
{
    print_example_name("A room in a roguelike");

    Room :: struct
    {
        monsters := 0;
    };
    room_with_monsters :: (room : *Room)
    {
        //
        // Something that might not be immediately obvious is that when you call yield() you
        // have to take into account that when the coroutine is resumed, lots of data could have
        // changed. For example, lets say that you're spawning a monster and get a handle to it.
        //
        //     monster_handle := create_monster();
        //     monster_pointer := get_monster_memory(monster_handle);
        //     monster_pointer.name = "Antoine";
        //     yield();
        //     monster_pointer.health += 10; // This could be invalid! Check that the handle is still valid and get the pointer again.
        // 
        // After yielding, the player could have killed the monster and the monster could have been
        // deleted, if the coroutine has gotten a pointer to that memory, that could now be invalidated.
        //
        // This is just one of the most clearly obvious cases, but in general with any sort of data that's
        // referentiable outside the coroutine, issues could happen if you don't have it in mind.
        //
        // This obviously can happen without coroutines, for example with explicit state machines that do the
        // same functionality. But there you need to be more explicit about the things that are referenced, they
        // aren't comfortably available on local variables in the stack or registers, so the issue is easier to miss
        // when using coroutines.
        //
        // Another example:
        //
        //     if is_alive(monster)
        //     {
        //         heal(monster, 10);
        //         wait_for(2.0); // which yields
        //         heal(monster, 10);
        //     }
        //
        // This above is potentially incorrect, because the monster could have died in the yields that happen
        // while we're waiting for 2 seconds. So what that code probably meant was to do the following:
        //
        //     if is_alive(monster)
        //     {
        //         heal(monster, 10);
        //         wait_for(2.0); // which yields
        //     }
        //     if is_alive(monster)
        //     {
        //         heal(monster, 10);
        //     }
        //

        // Because we can jump back to our caller at any point maintaining out
        // local state, we can do stuff like this that would need to wait for a
        // certain time, but letting the caller resume with processing. In this case
        // this whole loop will complete over many ticks/frames of our game.
        print("Spawning a monster every second\n");
        for 0..9
        {
            room.monsters += 1;
            print("Monster count is % because we just spawned one!\n", room.monsters);
            wait_for(1.0);
        }

        // Note that this isn't an active sleep, not even really acting as a loop. Once
        // per tick/frame, this will get called, see if there isn't any monsters left and
        // return back to the caller. Whenever the monsters are all dead, the loop will
        // end and continue the coroutine.
        print("Waiting for the player to kill all monsters\n");
        while room.monsters > 0 yield();

        print("The player killed all the monsters uh? Open the door!\n");
    }

    room : Room;
    coroutine : Coroutine(type_of(room_with_monsters));
    init(*coroutine, room_with_monsters, *room);
    defer deinit(*coroutine);

    // This would be the game loop, running the coroutine once per frame.
    while !is_done(*coroutine)
    {
        run(*coroutine);

        // Let's simulate a user fighting the monsters, with a small chance that they
        // kill one in a given frame. If this was an actual game, you'd run the rest of your
        // frame in here, reading user input, updating to see if it killed the monsters or not,
        // rendering, etc.
        if room.monsters > 0 && random_get_zero_to_one() < 0.0000002 
        {
            room.monsters -= 1;
            print("Monster count is % because the player killed one!\n", room.monsters);
        }
    }
}



text_adventure_conversation :: ()
{
    print_example_name("A conversation in some text adventure game");

    conversation :: ()
    {
        present_text("Hello adventurer!\n");
        wait_for(1.0);
        present_text("Would you be interested in<...> some of my more <<*ExOtIC*>> artifacts?\n");
        while true
        {
            user_said := read_input("[yes/no]: ");
            if user_said == "yes"
            {
                present_text("I have some magical chewing gum, it says strawberry but really tastes like apricots<...>\nHere you go\n");
                break;
            }
            else if user_said == "no"
            {
                present_text("Uhhh, too good for the black market ah?<<\0>> Well that's >>racist<<.<<\0>>\n");
                break;
            }
            else
            {
                present_text("I didn't quite catch that, I'm not ChatGPT man.\n");
            }
        }
        present_text("Now be on your way!\n");
    }

    //
    // On the other examples we've been using type_of(the_coroutine_code) so we don't have to
    // think much about what's the actual type of the procedure the coroutine is meant
    // to call. However, we can just explicitly write the type the procedure has, in this
    // case it's a procedure with no arguments and no return values, so it's simply "#type ()"
    //
    coroutine : Coroutine(#type ());
    init(*coroutine, conversation);
    defer deinit(*coroutine);

    while !is_done(*coroutine)
    {
        run(*coroutine);
    }
}



doing_allocations :: ()
{
    print_example_name("Allocating dynamic memory");

    shuffle :: (input : string, output : *string)
    {
        print("The user passed us \"%\" (%)\n", input, input.data);
        yield();

        //
        // Here we're showing an example of using the temporary allocator
        // via talloc(...). For coroutines, since they have their own context,
        // you can use temporary allocations which will go into the temporary
        // storage of that coroutine.
        //
        // This temporary storage will get cleared when the coroutine returns
        // so you can use it as a buffer to hold dynamic allocations for the duration
        // of the coroutine. Similar to how "alloca" would work in C.
        //
        // Another benefit of using temporary allocations is that you don't need to
        // make sure to free them before you stop calling the coroutine. If you
        // were to use classic heap allocations, it would be easy to terminate the
        // coroutine early, without giving it the chance to free something, for example:
        //
        //     the_coroutine_code :: ()
        //     {
        //         data := alloc(...);
        //         yield();     // <- The execution comes back to the caller, and we might never return here!
        //         free(data);  //    That would make this call never execute, therefore we'd leak.
        //     }
        //
        // If the user decides to stop calling the coroutine after that first yield then
        // the data will never be freed. This can happen still with things like defer.
        //
        // By using temporary memory you sidestep the posibility for this kind of leak.
        //
        //
        buffer : []u8;
        buffer.count = input.count;
        buffer.data = talloc(buffer.count);
        memcpy(buffer.data, input.data, input.count);

        print("We copied it to a buffer in the coroutine's temporary memory: \"%\" (%)\n", cast(string)buffer, buffer.data);
        yield();

        for i : 0..buffer.count-2
        {
            j := i + cast(int)(random_get() % cast(u64)(buffer.count - i));
            temp := buffer[i];
            buffer[i] = buffer[j];
            buffer[j] = temp;
        }

        print("We shuffled the buffer to get: \"%\" (%)\n", cast(string)buffer, buffer.data);
        yield();

        //
        // And since this is normal code, you can obviously do classic heap allocations
        // as well. In fact, here you'd want to do a heap allocation to pass to the user
        // as the result, because if you passed the result in the coroutine's temporary memory
        // that would be invalidated when the coroutine terminates and gets deinitialized.
        //
        // This might seem obvious, but in general the issue with leaks in coroutines (and in general)
        // is not that you did an allocation, is that you might not execute a free(...) for that 
        // allocation when you did intend to. It's the chance that the coroutine never executes a
        // free(...) that you meant to execute.
        //
        // In this case there's no worries, this is data that we're passing to the user that they
        // will then have to manage however they want to.
        //
        output.count = buffer.count;
        output.data = alloc(output.count);
        memcpy(output.data, buffer.data, buffer.count);
        print("We copied it to the output so the user can see it, we did this in the heap: \"%\" (%)\n", output.*, output.data);
    }

    string_to_shuffle := "Hello sailor!";
    shuffled_string : string;

    coroutine : Coroutine(type_of(shuffle));
    init(*coroutine, shuffle, string_to_shuffle, *shuffled_string);
    defer deinit(*coroutine);
    while !is_done(*coroutine)
    {
        run(*coroutine);
    }

    print("The coroutine gave us the shuffled string: \"%\" (%)", shuffled_string, shuffled_string.data);
    free(shuffled_string);
}



custom_stack_memory :: ()
{
    print_example_name("Using the provided memory for the stack");

    the_coroutine_code :: ()
    {
        a := 1;
        b := 2.0;
        c := true;
        print("A, B, C, D = %(%), %(%), %(%)\n", a,*a, b,*b, c,*c);
        yield();
        a += 1;
        b += 1;
        c ^= true;
        print("A, B, C, D = %(%), %(%), %(%)\n", a,*a, b,*b, c,*c);
        yield();
        a *= 2;
        b *= 2;
        c |= true;
        print("A, B, C, D = %(%), %(%), %(%)\n", a,*a, b,*b, c,*c);
    }

    buffer : []u8;
    buffer.count = 32 * 1024;
    buffer.data  = alloc(buffer.count); 
    defer free(buffer.data);
    print("My stack memory goes from % to %\n", buffer.data, buffer.data + buffer.count);

    coroutine : Coroutine(type_of(the_coroutine_code));
    init(*coroutine, procedure = the_coroutine_code, stack = buffer);
    defer deinit(*coroutine);
    while !is_done(*coroutine)
    {
        run(*coroutine);
    }
}



#scope_file



//
// This is a very useful construction if you're calling coroutines this way, it's not
// a generic function of the module because you might want to make this depend on different
// times, like your gameplay time (paused in some cases) instead of system time. But wanted
// to have it here in the example because it's something you might wanna do :)
//
wait_for :: (time : float) #expand
{
    // Because the non-volatile registers and the stack are maintained, we can
    // save the starting time as a variable and compare it every frame, see if
    // we have waited for enough time.
    start := no_inline current_time_monotonic();
    while to_float64_seconds(current_time_monotonic() - start) < time 
    {
        yield();
    }
}



//
// Similar construct as the wait_for() procedure above, we can simulate text
// getting revealed character by character very easily with a loop.
//
present_text :: (text : string) #expand
{
    DELAYS :: float.[0.6, 0.3, 0.05, 0.02, 0.01];
    current_delay_index := 2;
    for 0..text.count-1
    {
        // So we can slow down text <like this> and speed it up >like this< for funsies
        if text[it] == 
        {
            case #char "<"; current_delay_index -= 1; continue;
            case #char ">"; current_delay_index += 1; continue;
        }

        char : string;
        char.data  = *text[it];
        char.count = 1;
        time := DELAYS[clamp(current_delay_index, 0, DELAYS.count-1)];
        start := no_inline current_time_monotonic();
        while to_float64_seconds(current_time_monotonic() - start) < time 
        {
            yield();
        }
        write_string(char);
    }
}



//
// Making one of these cause at the time of writing there's no standard way to read from
// standard input. This does the job for this example though.
//
read_input :: (prompt := "") -> string
{
    write_string(prompt);

    buffer : []u8;
    buffer.count = 128;
    buffer.data = talloc(buffer.count);
    #if OS == .WINDOWS
    {
        #import "Windows";
        bytes_read : u32;
        success := ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer.data, xx buffer.count, *bytes_read, null);
        assert(success == .TRUE);
    }
    else #if OS == .LINUX || OS == .MACOS
    {
        #import "POSIX";
        bytes_read := read(STDIN_FILENO, buffer.data, xx buffer.count);
        assert(bytes_read >= 0);
    }
    if bytes_read
    {
        result : string;
        result.data  = buffer.data;
        result.count = bytes_read;
        if result[result.count-1] == #char "\n" result.count -= 1;
        if result[result.count-1] == #char "\r" result.count -= 1;
        return result;
    }
    return "";
}



print_example_name :: (name : string) #expand
{
    for 0..(8 + name.count)-1 print("#");
    print("\n### % ###\n", name);
    for 0..(8 + name.count)-1 print("#");
    print("\n");
    `defer print("\n\n\n");
}