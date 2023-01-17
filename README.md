# :running: osor_coroutine

A coroutine module for the Jai programming language. You can check the code in [module.jai](module.jai) then a few examples of how to use them in [example.jai](example.jai)

## Notes

I would like to reimplement this one day directly with Jai's inline assembly (`#asm`) and by handling Jai's specific calling convention, non-volatile registers, ways of setting the stack and the context, etc. As I'm writing this, these don't exist or are not available to me so this module works by "going to C land" and working with the knowledge of the different x64 conventions.

The way Jai generates x64 code, what lives on the stack, how it uses the registers and the context, etc. are things that at the time of writing are subject to change. This module avoid those problems by going through `#c_call` function calls, storing/restoring all the state dictated by the ABIs when switching to/from coroutines, etc. That said, there might be future changes with the language where the state that we handle isn't enough or it interacts with the language constructs in unexpected ways. If you find any issues please report them so they can be fixed!

## License

I want people to be able to just use this without thinking about licensing, although give me a shout if you do use it and attribution is appreciated 😊. Replicating STB's (https://github.com/nothings/stb) licensing stuff where you can choose to use public domain or MIT.
