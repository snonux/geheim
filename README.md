# geheim.rb

This is an humble Ruby script for text and binary document encryption. It uses `AES-256-CBC` by default and the initialization vector is generated from an user input PIN.

This is for my own use. So the documentation here may be lacking. But feel free to try out yourself or ask!

## Features

* Encrypts and stores any type of documents and files (text, binary, etc). Meant for smaller files, such as text, PDFs, etc.
* All documents are stored in a Git repository.
* All file names are encrypted as well and kept in encrypted files in the same Git repository themselves.
* The indices are searchable through `fzf`, the fuzzy finder.
* The Git repository can be synchronized with N remote Git repositories.
* Text entries are edited using NeoVim (with cache files etc. disabled).
* Works on MacOS, Linux and on Android via Termux.
* Clipboard support for MacOS and GNOME (Linux).
* Interactive `geheim` shell support.
* Can import and export documuments in batches.
* Can shred exported data again.
