# y: yobibyte's text editor

I am following [kilo](https://viewsourcecode.org/snaptoken/kilo/index.html) tutorial but in Zig.
The goal is to get to something simple first, and then add modalities/vim keybindings etc.

This is still too early, but this is the subset of vim I care about. I wonder how far can I push this.
- normal/visual/replace mode
- vim motions
- go to a line number with :<line number>
- search and replace
- tab expansion, controlling tabwidth
- commenting out code with language-dependent comment chars
- multiple buffers
- vertical/horizontal splits
- an ability to run a bash command from the editor
- an ability to pipe the output from above to an open buffer (or create a buffer with it)
- quickfix list
- undo file
- using system's clipboard (vim.o.clipboard = "unnamedplus")
