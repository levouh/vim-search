fu! s:wrap(seq) " {{{1
    if mode() == 'c' && stridx('/?', getcmdtype()) < 0
        " Command was not a search, return early
        return a:seq
    endif

    " Remove current search match highlighting if it exists
    if exists('w:blink_id')
        call s:match_del()
    endif

    " Remove the autocommand group that is used to clear search
    " highlighting, it will be setup again as part of the process
    " to make it a "one shot" execution
    silent! autocmd! search
    set hlsearch

    return a:seq .. "\<plug>(search-trailer)"
endfu

fu! s:match_del() " {{{1
    try
        " Clear the highlighting for the current match,
        " or at least try to.
        call matchdelete(get(w:, 'blink_id', -1))
    catch
        " There are cases where this may not be set,
        " in which case we want to do nothing as the
        " highlight does not exist in the first place.
    endtry

    return ''
endfu

fu! s:highlight_timer() " {{{1
    " In order to have the highlighting of the current match work
    " correctly, the call needs to not block as the cursor won't
    " be in the right position until the right hand side of
    " the ":h <expr>" mapping is completed.
    "
    " ":h timer_start" just sets up a callback, so things do not
    " run in parallel, but the callback should be executed almost
    " immediately after the "s:trailer()" method finishes
    call timer_start(1, {-> s:highlight() })
endfu

fu! s:highlight(...) " {{{1
    " The timeout in milliseconds to stop looking for the match
    let timeout = 30
    let pos = [line('.'), col('.')]

    " Limit the search to a specific range for performance reasons,
    " this denotes 25 lines above and 25 lines below
    let context = 25

    " We could be at the top of the file, so the line number might
    " be 1 for instance, and subtracting 25 from that would make
    " it negative, so we need to ensure we don't produce a bad value
    let top = max([1, pos[0] - context])

    " For the 'stopline' searching downwards, it doesn't matter
    let bottom = pos[0] + context

    "    ┌ returns a list with the line and column position of the match respectively
    "    │                ┌ the pattern for the match, i.e. the current search
    "    │                │    ┌ search backwards
    "    │                │    │┌ accept match at cursor position
    "    │                │    ││
    "    │                │    ││
    let start = searchpos(@/, 'bc', top, timeout)
    "                                │         │
    "                                │         └ timeout in milliseconds
    "                                └ the line to stop the search at

    if start == [0, 0]
        " No match found, stop early
        return ''
    endif

    "                   ┌ the pattern for the match, i.e. the current search
    "                   │    ┌ start searching at the cursor position
    "                   │    │┌ allow a match at the cursor position
    "                   │    ││┌ move to the end of the match
    "                   │    │││┌ do not move the cursor
    "                   │    ││││
    let end = searchpos(@/, 'zcen', bottom, timeout)
    "                                  │       │
    "                                  │       └ timeout in milliseconds
    "                                  └ the line to stop the search at

    if end == [0, 0]
        " No match found, stop early
        return ''
    endif

    " Determine whether or not we are currently inside a match based on the start and end positions of the match
    " as found above
    "               ┌ on or past line     ┌ on or past column   ┌ on or before line ┌ on or before column
    "               │ start               │ start               │ end               │ end
    "               ├────────────────┐    ├────────────────┐    ├──────────────┐    ├──────────────┐
    let is_inside = pos[0] >= start[0] && pos[1] >= start[1] && pos[0] <= end[0] && pos[1] <= end[1]

    if is_inside
        "           ┌ use magic, although it seems like "matchadd()" will do this by default
        "           │ ┌ a number will follow this, so this is searching in the line
        "           │ │ specified by the number that follows it
        "           │ │       ┌ the line to search on, see ":h /ordinary-atom"
        "           │ │       │        ┌ specify the 'l'ine
        "           │ │       │        │
        let pat = '\m\%' . start[0] . 'l\%' . start[1] . 'c'
        "                                │       │        │
        "                                │       │        └ specify the 'c'olumn
        "                                │       └ column from "searchpos()"
        "                                └ same idea as line, but specify the column

        if start != end
            "    ┌ do the same as above, but continue towards the end of the line
            "    │                                            ┌ small nuance here is to not match end-of-line
            "    │                                            │
            let pat .= '\_.*\%' . end[0] . 'l\%' . end[1] . 'c.'
        endif

        " Use the pattern to highlight the current match properly
        "
        "                                             ┌ specifies the priority versus other highlight groups
        "                                             │
        let w:blink_id = matchadd('IncSearch', pat, 1000, get(w:, 'blink_id', -1))
        "                                                                      │
        "                                                                      └ use the next free ID if none have been found
    endif

    return ''
endfunction


fu! s:immobile(seq) " {{{1
    " Adds map to call a function that essentially runs
    " "``" if the mapping should be "immobile", meaning
    " that the cursor won't move when the command is issued.
    " List of position information for the cursor.
    let s:pos = getpos('.')

    " Mentioned above, add mapping to expression sequence
    " that actually performs "immobile" functionality.
    return a:seq .. "\<plug>(search-prev)"
endfu

fu! s:trailer() " {{{1
    " This function is called after the main functionality
    " is performed, so for example the "n" key will have
    " already been pressed.
    "
    " Open folds if inside of one.
    let seq = foldclosed('.') != -1 ? 'zv' : ''

    " See if the user has any mappings to be performed after the search
    " is done, if so, tack them on the the end of this chain
    let after = len(maparg("<plug>(search-after)", mode())) ? "\<plug>(search-after)" : ''

    " Show a count of the current search match out of a total count
    let search_count = "\<plug>(search-count)"

    " Highlighting the current match uses the "e" argument to find the end of the match,
    " which will move the cursor, causing the "search" autocommand group to trigger too
    " early. This needs to go after the "<plug>(search-hl)" mapping as a result.
    let search_au = "\<plug>(search-au)"

    " Setup callback to highlight the current match
    call s:highlight_timer()

    return seq .. search_count .. search_au .. after
endfu

fu! s:search_count() " {{{1
    " The max number of matches for ":h searchcount()"
    let maxcount = 1000

    " Timeout before ":h searchcount()" stops searching
    let timeout = 500

    try
        let result = searchcount({'maxcount': maxcount, 'timeout': timeout})
        let [current, total, incomplete] = [result.current, result.total, result.incomplete]
    catch
        " In case the pattern is invalid (`E54`, `E55`, `E871`, ...)
        echohl ErrorMsg | echom v:exception | echohl NONE

        return ''
    endtry

    let msg = ''

    " We don't want a NUL to be translated into a newline when echo'ed as a string;
    " it would cause an annoying hit-enter prompt
    let pat = substitute(@/, '\%x00', '^@', 'g')

    if incomplete == 0
        " ":h printf()"  adds a  padding  of  spaces to  prevent  the pattern  from
        " "dancing" when cycling through many matches by smashing `n`
        let msg = pat .. ' [' .. printf('%*d', len(total), current) .. '/' .. total .. ']'
    elseif incomplete == 1 " Recomputing took too much time
        let msg = pat .. ' [?/?]'
    elseif incomplete == 2 " Too many matches
        if result.total == (result.maxcount+1) && result.current <= result.maxcount
            let msg = pat .. ' [' .. printf('%*d', len(total - 1), current) .. '/>' .. (total - 1) .. ']'
        else
            let msg = pat .. ' [>' .. printf('%*d', len(total - 1), current - 1) .. '/>' .. (total - 1) .. ']'
        endif
    endif

    " We don't want a hit-enter prompt when the message is too long.
    "
    " Let's emulate what Vim does by default:
    "
    "    - Cut the message in 2 halves
    "    - Truncate the end of the 1st half, and the start of the 2nd one
    "    - Join the 2 halves with `...` in the middle
    "
    if strchars(msg, 1) > (v:echospace + (&cmdheight - 1)*&columns)
    "                      ├─────────┘   ├─────────────────────┘
    "                      │             └ space available on previous lines of the command-line
    "                      └ space available on last line of the command-line
    "
        let n = v:echospace - 3
        "                     │
        "                     └ for the middle '...'

        let [n1, n2] = n%2 ? [n/2, n/2] : [n/2-1, n/2]
        let msg = join(matchlist(msg, '\(.\{' .. n1 .. '}\).*\(.\{' .. n2 .. '}\)')[1:2], '...')
    endif

    echo msg

    return ''
endfu

fu! s:setup_au() " {{{1
    " This function sets up a one-time autocommand when the
    " window focus changes or the cursor moves to ensure that
    " the ":h hlsearch" is turned off, and the highlighting,
    " set above, is cleared.
    augroup search | au!
        au CursorMoved,CursorMovedI,CmdLineEnter,WinLeave * set nohlsearch | call <sid>match_del() | autocmd! search
    augroup END

    return ''
endfu

fu! s:trailer_on_leave() " {{{1
    augroup search | au!
        au InsertLeave * call <sid>trailer()
    augroup END

    return ''
endfu

fu! s:prev() " {{{1
    " In order to maintain the cursor position when searching, issue the "normal" command
    " first, like "n". Vim will read this and move forward to the next match for things
    " like "*" as it normally would, but instead, hop backwards to the match where the
    " command started to make it "immobile".
    "
    " This is done by executing "``", which will jump backwards to the previous cursor
    " position, achieving this effect.
    return getpos('.') == s:pos ? '' : '``'
endfu

fu! s:escape(backward) " {{{1
    " If searching backwards, the "command" will change
    let search_cmd = '\' .. (a:backward ? '?' : '/')

    "       ┌ only "\", "/", or "?" are treated as special characters
    "       │
    "       │                        ┌ escape backslashes that occur in the '"'
    "       │                        │ register that is forming the search
    "       │                        │
    return '\V' .. substitute(escape(@", search_cmd), "\n", '\\n', 'g')
    "                                                   │           │
    "                             do the same with "\n" ┘           └ replace all matches
endfu

" Mappings {{{1
" Setting up ":h using-<Plug>" mappings here is not completely
" necessary, but because a lot of these are used multiple times
" it is easier to just have a simple name for them.
"
" Called after the wrapped action is performed to do things
" like setup search count, start the highlight timer, etc.
map <expr> <Plug>(search-trailer) <SID>trailer()

" Count the number of matches for the current search item,
" and echo them in the command-line along with the search
" text.
"
" These will be displayed like "term [X/X]"
map <expr> <Plug>(search-count) <SID>search_count()

" In order to have the highlighting of the current match work
" correctly, the call needs to not block as the cursor won't
" be in the right position until the right hand side of
" the ":h <expr>" mapping is completed.
"
" ":h timer_start" just sets up a callback, so things do not
" run in parallel, but the callback should be executed almost
" immediately after the "s:trailer()" method finishes
map <expr> <Plug>(search-hl) <SID>highlight_timer()

" This function sets up a one-time autocommand when the
" window focus changes or the cursor moves to ensure that
" the ":h hlsearch" is turned off, and the highlighting,
" set above, is cleared.
map <expr> <Plug>(search-au) <SID>setup_au()

" This one does the same as above, but it deals more with
" entering/exiting insert mode.
"
" This was initially setup as a part of "vim-slash", but
" I'm not entirely sure when exactly it is used.
imap <expr> <Plug>(search-trailer) <SID>trailer_on_leave()

" A simple press of the enter key, use a ":h <Plug>"
" mapping to avoid conflicts and for conistency.
cnoremap <Plug>(search-cr) <CR>

" Calls a function that essentially just runs "``" if
" the mapping should be "immobile", meaning that the
" cursor won't move when the command is issued.
"
" Normally, when using something like "*", Vim will
" automatically jump to the next match, but this will
" just highlight the current match instead.
noremap <expr> <Plug>(search-prev) <SID>prev()

" Things can happen from insert mode as well, and in that
" case we don't want to insert "``" unecessarily.
inoremap <Plug>(search-prev) <nop>

" Map this for the commandline, so that when the enter key
" is pressed to finish a search, the "s:trailer()" method
" can be called afterwards.
"
" This will not happen for every single thing done from the
" commandline, done by checking ":h getcmdtype()".
cmap <expr> <CR> <SID>wrap("\<CR>")

" Wrap simple search-related commands.
map  <expr> n    <SID>wrap('n')
map  <expr> N    <SID>wrap('N')
map  <expr> gd   <SID>wrap('gd')
map  <expr> gD   <SID>wrap('gD')

" These are deemed "immobile", meaning that the cursor won't
" be moved immediately when the command is issued like it would
" as a part of normal Vim behavior.
map  <expr> *    <SID>wrap(<SID>immobile('*'))
map  <expr> #    <SID>wrap(<SID>immobile('#'))
map  <expr> g*   <SID>wrap(<SID>immobile('g*'))
map  <expr> g#   <SID>wrap(<SID>immobile('g#'))

" In order to allow larger visual selections, add some extra
" logic to first yank the visual selection, and then paste
" it into the command line to allow it to be searched.
"
"                                         ┌ yank the visual selection into the '"' register
"                                         │    ┌ insert the contents of a register
"                                         │    │  ┌ use expression register to allow
"                                         │    │  │ inserting of a particular expression
"                                         │    │  │
xmap <expr> *    <SID>wrap(<SID>immobile("y/\<C-r>=<SID>escape(0)\<Plug>(search-cr)\<Plug>(search-cr)"))
"                                                           │             │                │
"                      escape necessary characters based on │             │                └ complete search
"                                          search direction ┘             └ complete expression
xmap <expr> #    <SID>wrap(<SID>immobile("y?\<C-r>=<SID>escape(1)\<Plug>(search-cr)\<Plug>(search-cr)"))
