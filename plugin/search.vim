if !has('timers') || exists('g:_loaded_search') " {{{1
  finish
endif

let g:_loaded_search = 1

" Options {{{1

const s:SEARCH_COUNT_MAX = 1000
const s:SEARCH_TIMEOUT = 500

fu! s:wrap(seq) " {{{1
    " Command is search, or empty, all other return values
    " from ":h getcmdtype()" should be skipped
    let valid_cmd = getcmdtype() =~ '/\|?\|^$'
    "                                │  │   │
    "                                │  │   └ empty, so no command
    "                                │  └ backward search
    "                 forward search ┘

    " Only accept options from normal, visual, and command mode
    let valid_mode = mode() =~ '[cnv]'

    if !valid_mode || !valid_cmd
        " Not an action that should be handled by this plugin,
        " so return early
        return a:seq
    endif

    " Remove the autocommand group that is used to clear search
    " highlighting, it will be setup again as part of the process
    " to make it a "one shot" execution
    silent! autocmd! search
    set hlsearch

    " This value is checked, but not cleared by Vim itself, so
    " do that manually as it can mess with some logic if the value
    " persists between searches
    let v:errmsg = ''

    return a:seq .. "\<Plug>(search-trailer)"
endfu

fu! s:match_del() " {{{1
    try
        " Clear the highlighting for the current match,
        " or at least try to.
        "
        " Only one match should be highlighted at any given
        " time, so don't delete the window-local variable,
        " just delete the match associated with it
        call matchdelete(get(w:, 'blink_id', -1))
        unlet w:blink_id
    catch
        " There are cases where this may not be set,
        " in which case we want to do nothing as the
        " highlight does not exist in the first place.
    endtry

    return ''
endfu

fu! s:highlight_timer() abort " {{{1
    " In order to have the highlighting of the current match work
    " correctly, the call needs to not block as the cursor won't
    " be in the right position until the right hand side of
    " the ":h <expr>" mapping is completed.
    "
    " ":h timer_start" just sets up a callback, so things do not
    " run in parallel, but the callback should be executed almost
    " immediately after the "s:trailer()" method finishes
    call timer_start(1, {-> s:highlight()})
endfu

fu! s:highlight(...) abort " {{{1
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

        if get(w:, 'blink_id', v:none) isnot# v:none
            " A highlight for the current window already exists, remove it
            call s:match_del()
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
    return a:seq .. "\<Plug>(search-prev)"
endfu

fu! s:trailer() " {{{1
    " This function is called after the wrapper for the pressed key.
    "
    " Show a count of the current search match out of a total count
    let search_count = "\<Plug>(search-count)"

    " Highlighting the current match uses the "e" argument to find the end of the match,
    " which will move the cursor, causing the "search" autocommand group to trigger too
    " early.
    let search_au = "\<Plug>(search-au)"

    " Setup/restore a view when searching that includes opening/closing folds, etc.
    let view_restore = "\<Plug>(search-view)"

    " Setup callback to highlight the current match
    call s:highlight_timer()

    return search_count .. search_au .. view_restore
endfu

fu! s:trailer_on_leave() " {{{1
    augroup search | au!
        au InsertLeave * call <SID>trailer()
    augroup END

    return ''
endfu

fu! s:view() abort "{{{1
    " Make a nice view, by opening folds if any, and by restoring the view if
    " it changed but we wanted to stay where we were (happens with "*" & friends)
    let seq = foldclosed('.') != -1 ? 'zMzv' : ''

    return seq
endfu

fu! s:search_count() " {{{1
    " The max number of matches for ":h searchcount()"
    let maxcount = s:SEARCH_COUNT_MAX

    " Timeout before ":h searchcount()" stops searching
    let timeout = s:SEARCH_TIMEOUT

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
        " ":h printf()" adds a padding of spaces to prevent the pattern from
        " "dancing" when cycling through many matches by smashing "n"
        let msg = pat .. ' [' .. printf('%*d', len(total), current) .. '/' .. total .. ']'
    elseif incomplete == 1 " Recomputing took too much time
        let msg = pat .. ' [?/?]'
    elseif incomplete == 2 " Too many matches
        if result.total == (result.maxcount + 1) && result.current <= result.maxcount
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

        let n = v:echospace - 3
        "                     │
        "                     └ for the middle '...'

        let [n1, n2] = n%2 ? [n / 2, n / 2] : [n / 2 - 1, n / 2]
        let msg = join(matchlist(msg, '\(.\{' .. n1 .. '}\).*\(.\{' .. n2 .. '}\)')[1:2], '...')
    endif

    echo msg

    return ''
endfu

fu! s:setup_au(...) " {{{1
    " This function sets up a one-time autocommand when the
    " window focus changes or the cursor moves to ensure that
    " the ":h hlsearch" is turned off, and the highlighting,
    " set above, is cleared.
    augroup search | au!
        au CursorMoved,CursorMovedI,CmdLineEnter,WinLeave * set nohls | call <SID>match_del() | autocmd! search

        " Necessary when a search fails, see ":h E486", and we search for another pattern right afterward.
        "
        " Otherwise, if there is no cursor motion between the two searches, and
        " the second one succeeds, the cursor does not blink.
        if a:0
            au CmdlineEnter * exe 'au! search' | aug! search | set nohls
        endif
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

fu! s:nohls() " {{{1
    " Calculates all permutations of the word "monkey"
    set nohls
endfu

fu! s:after_slash() abort " {{{1
    if getcmdline() is# '' || v:errmsg[:4] is# 'E486:'
        " There are a few use cases for this:
        "
        "     1. Don't enable 'hls' when this function is called because the command-line
        "        was entered from the RHS of a mapping, especially useful for "/ Up CR C-o".
        "     2. When the user has typed someting into the command-line, but they didn't
        "        finish it by hitting "<CR>".
        "     3. In the case that a search is issued in one window and a match is not found in the
        "        window from which the search was issued, matches in other windows will still be
        "        highlighted, so catch this error and remove the highlight so that it doesn't
        "        exist in other windows
        "
        " Because of these situations, ":h hls" will be left on, which is not what we want.
        " Use a timer to avoid the "Press Enter to Continue" prompts.
        call timer_start(0, {-> s:nohls()})
    endif
endfu

fu! s:cmdwin_enter() " {{{1
    " Because of the way that some of the searching works, highlights
    " might happen for things _in_ the command-line window, which isn't
    " a problem for the most part, but can be a bit distracting
    set nohls

    " This value is checked, but not cleared by Vim itself, so
    " do that manually as it can mess with some logic if the value
    " persists between searches
    let v:errmsg = ''

    " Setup a mapping for when the user presses "enter" from this window
    " to execute a search for a given item
    nnoremap <buffer> <expr> <CR> <SID>cmdwin_wrap("\<CR>")
endfu

fu! s:cmdwin_wrap(seq) " {{{1
    " Setup a timer so that this will happen _after_ the autocommands, etc.
    " for when the command-line window is closed, at least in theory.
    "
    " This is necessary because the search should not happen _in_ the
    " command-line window, but rather the window that is focused
    " once it is closed
    call timer_start(5, {-> s:after_cmdwin()})

    " The only argument to this function should really be "<CR>", but
    " there might be other use cases for it.
    return a:seq
endfu

fu! s:after_cmdwin() " {{{1
    " This function is called via a timer once the command-line
    " window has been closed, at least in theory
    "
    " At this point, the contents of ":h @/" will have the term
    " that should be searched for, so continue as normal with
    " highlighting, etc.
    if v:errmsg[:4] is# 'E486:'
        " The term was not found, no point in trying again
        "
        " This also prevents the ":h feedkeys()" entered
        " from issuing commands for the wrong search
        return
    endif

    " Go to the next match, and then back to the one that
    " would have been returned when exiting the command-line
    " window anyways
    "
    " The problem here is that the search has already been
    " issued, so this will automatically move to the _next_
    " match after it, which is not what we want. So go
    " forward, and then backward so that we end up in the
    " same spot.
    "
    " The default behavior is to remap keys, which is exactly
    " what we want
    "
    " TODO: There should really be a better way to do this,
    "       as at this point "@/" is correctly set, so the
    "       search can be performed raw again.
    call feedkeys("nN")
endfu

augroup cmdline_hl " {{{1
    au!

    " If 'hls' and 'is' are set, then _all_ matches are highlighted when we're
    " writing a regex, not just the next match noted in ":h is".
    au CmdlineEnter /,\? set hls

    " Once the search is complete, make sure that the setting above makes sense
    " to persist, for instance if there were no matches found, etc.
    au CmdlineLeave /,\? call <SID>after_slash()
augroup END

augroup cmdwin_hl " {{{1
    au!

    " When the command-line window is entered, setup a binding
    " for when the user selects an option
    "
    " Only do this for serach-related command-line windows
    au CmdwinEnter /,\? call <SID>cmdwin_enter()
augroup END

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

" Save/restore the view when moving between search matches
" which includes opening/closing folds, etc.
nmap <expr> <Plug>(search-view) <SID>view()

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

" We need this mapping for when we leave the search command-line from visual mode.
xno <expr> <plug>(search-visleave) search#nohls()
