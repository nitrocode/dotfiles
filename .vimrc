set nocompatible
set backspace=indent,eol,start
set backup
set history=50
set ruler
set background=dark
set showcmd
set incsearch
"set bs=2
syntax on
set hlsearch
set expandtab
set tabstop=4
set shiftwidth=4
set nobackup
set nowritebackup
"This should maintain LF instead of CRLF
"http://unix.stackexchange.com/a/44642
set fileformat=unix
set fileformats=unix,dos
"set nobinary
set number

if has("autocmd")

    " If the filetype is Makefile then we need to use tabs
    " So do not expand tabs into space.
    autocmd FileType make   set noexpandtab

endif
