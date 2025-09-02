# y: yobibyte's text editor

`y` is a highly opionated text editor written by yobibyte.
It started as following the[kilo](https://viewsourcecode.org/snaptoken/kilo/index.html) tutorial in Zig, but grew out in something bigger.
The goal is to reimplement a subset of vim I use to do my work and switch from vim to y.

## Philosophy

**Radical simplicity**
I will not be overengineering this. 
I will implement everything the dumbest way possible until I hit a performance or maintenance issue.
Every line of code is an enemy.
I will not be implementing features I do not need.
For instance, I do not need syntax highlighting, and I will not be implemented that.
I do not need to support every possible use-case or enable the community to modify the editor with a scripting language.
I do not need LSP support or anything similar.
I do not need a complicated build/release/CI system, everything should be local and fast.
This editor will not be configurable, if you want to use it, you will need to change the constants in the source code and rebuild.
This is also the reason I will not be supporting Windows and add if branches everywhere to do platform-dependent stuff.

**No dependencies**
I will implement everything from scratch. I will not be using any of zig libraries apart from the standard library of the language.
This is a great way to learn, but also makes me more robust.
Being self-reliant is a good thing

**Pacing yourself**
I do not have a PM asking me about new feature deadline.
I can use vim in the meantime, I am not in a rush.
I am here to have fun and learn.

## Roadmap
- [x] Text viewer chapter from the tutorial.
- [x] Text editor chapter from the tutorial.
- [x] Basic mode and motions support (normal/insert, hjkl).
- [x] Go to a line number with :<line number>.
- [x] Commenting out code with language-dependent comment chars.
- [ ] Search chapter from the tutorial.
- [ ] More advanced vim motions.
- [ ] Line wrapping.
- [ ] Search and Replace.
- [ ] Tab expansion, controlling tabwidth.
- [ ] Multiple buffers.
- [ ] Undo.
- [ ] Visual/replace mode.
- [ ] Using system's clipboard (vim.o.clipboard = "unnamedplus").
- [ ] An ability to run a bash command from the editor.
- [ ] An ability to pipe the output from above to an open buffer (or create a buffer with it).
- [ ] Utf8 support.
- [ ] Quickfix list.
- [ ] Vertical/horizontal splits.
