if exists('g:autoloaded_search')
    finish
endif
let g:autoloaded_search = 1

fu! search#after_slash() abort "{{{1
    call s:set_hls()

    " If we set 'lazyredraw', when we search a pattern absent from the buffer,{{{
    " the search command will be displayed, which gives:
    "
    "         • command
    "         • error
    "         • prompt
"}}}
    let s:lz_save = &lz
    set nolazyredraw
    augroup restore_lz
        au!
        au CmdlineLeave * let &lz = s:lz_save
            \ | unlet! s:lz_save
        au CmdlineLeave * exe 'au! restore_lz' | aug! restore_lz
    augroup END

    call feedkeys("\<plug>(ms_custom)", 'i')
endfu

fu! search#after_slash_status(...) abort "{{{1
    if a:0
        unlet! s:after_slash
        return ''
    endif
    return get(s:, 'after_slash', 1)
endfu

fu! search#blink() abort "{{{1
    " every time `search#blink()` is called, we  must reset the keys `ticks` and
    " `delay` in the dictionary `s:blink`
    let [s:blink.ticks, s:blink.delay] = [4, 50]

    call s:blink.delete()
    call s:blink.tick(0)
    return ''
endfu

fu! s:delete() abort dict "{{{1
    " This function has  side effects (it changes  the state of the  buffer), but we
    " also use it for its output.  In `s:blink.tick()`, we test the latter to decide
    " whether we should create a match.
    if exists('w:blink_id')
        call matchdelete(w:blink_id)
        unlet w:blink_id
        return 1
    endif
    " no need to return 0, that's what a function does by default
endfu

fu! search#escape(is_fwd) abort "{{{1
    return '\V'.substitute(escape(@", '\'.(a:is_fwd ? '/' : '?')), "\n", '\\n', 'g')
endfu

fu! search#index() abort "{{{1
    let [current, total] = s:matches_count()

    " We  delay  the `:echo`,  otherwise  it's  automatically  erased in  a  Vim
    " terminal buffer. Also, we  have come to the conclusion that,  to display a
    " message from a function called from a mapping, RELIABLY in Vim and Neovim,
    " we must avoid `<expr>`, and we must delay the `:echo`.
    "
    " For more info, see our mapping changing the lightness of the colorscheme.

    let msg = '['.current.'/'.total.'] '.@/
    call timer_start(0, {-> execute('echo '.string(msg), '')})
    " Do NOT use `printf()`:{{{
    "
    "         call timer_start(0, {-> execute(printf('echo ''[%s/%s] %s''', current, total, @/), '')})
    "
    " It would break when the search pattern contains a single quote.
    " We need `string()` to take care of the message BEFORE passing it to `:echo`.
    "
    " And we couldn't include `string()` inside the format passed to `printf()`:
    "
    "         execute(printf('echo string(%s)', msg))
    "
    " … because  when `printf()`  would replace the  %s item,  the surrounding
    " quotes around the  message would be removed, and  `string()` would receive
    " an  unquoted string  which  would often  cause  an error  (E121: Undefined
    " variable). The exact same thing happens here:
    "
    "       exe 'echo string('.msg.')'
    "
    " Remember:
    " `printf('…%s…%s…')` is really equivalent to a concatenation of strings.
    " That is,  after being  processed, the quotes  surrounding the  strings are
    " REMOVED in both cases:
    "
    "       echo 'here is '.var
    "     ⇔ echo printf('here is %s', var)
    "
    " This is why  we use `string()` (outside a `printf()`'s {fmt}):
    " to add a  2nd layer of quotes,  which will remain after the  1st layer has
    " been removed.
    "}}}
endfu


" matches_above {{{1

" Efficiently recalculate number of matches above current line using values
" cached from the previous run.
"
" How it works? ; if the current position is near:
"
"     - the end, it's faster to compute the number of matches from the current
"       line to the end, then subtract it from the total (the function is only
"       invoked if the buffer and the pattern haven't changed, so `total` is the
"       same as the last time)
"
"     - the position where we were last time we invoked this function,
"       it's faster to compute the number of matches between the 2 positions, then
"       add/subtract it from the cached number of matches which were above the
"       old position

fu! s:matches_above()
    " if we're at the beginning of the buffer, there can't be anything above
    "
    " it probably also prevents the range `1,.-1` = `1,0` from prompting us with:
    "
    "     Backwards range given, OK to swap (y/n)?
    if line('.') ==# 1 | return 0 | endif

    " this function is called only if `b:changedtick` hasn't changed, so
    " even though the position of the cursor may have changed, `total` can't
    " have changed ────────────┐
    "                          │
    let [old_line, old_before, total] = b:ms_cache

    let line = line('.')
    " find the nearest point from which we can restart counting:
    "         top, bottom, or previously cached line
    let to_top    = line
    let to_old    = abs(line - old_line)
    let to_bottom = line('$') - line
    let min_dist  = min([to_top, to_old, to_bottom])

    if min_dist ==# to_top
        return s:matches_in_range('1,.-1')

    elseif min_dist ==# to_bottom
        return total - s:matches_in_range('.,$')

    " otherwise, min_dist ==# to_old, we just need to check relative line order
    elseif old_line < line
        return old_before + s:matches_in_range(old_line.',.-1')
        "                   │
        "                   └─ number of matches between old position and
        "                   above current one

    elseif old_line > line
        return old_before - s:matches_in_range('.,'.old_line.'-1')
        "                   │
        "                   └─ number of matches between current position and
        "                   above last one

    else " old_line ==# line
        return old_before
    endif
endfu

" matches_count {{{1

" Return 2-element array, containing current index and total number of matches
" of last search pattern in the current buffer.
"
" We use `:s///gen` to compute the number of matches inside various ranges,
" because it seems faster than `:while + search()`.
" But, Ex commands only work on entire lines. So, we'll split the computing in
" 2 parts:
"
"     - number of matches above current line (`:s///gen`)
"     - number of matches on current line (`:while + search()`)

fu! s:matches_count() abort
    let view = winsaveview()
    " folds affect range of ex commands:
    "     https://stackoverflow.com/q/33190754/8243465
    "
    " we don't want folds to affect `:s///gen`
    let fen_save = &l:fen
    setl nofoldenable

    " We must compute the number of matches on the current line NOW.
    " As soon as we invoke `s:matches_above()` or `s:matches_in_range()`,
    " we'll be somewhere else.
    let in_line = s:matches_in_line()

    " check the validity of the cache we have stored in `b:ms_cache`
    " it's only useful if neither the pattern nor the buffer has changed
    let cache_id = [@/, b:changedtick]
    if get(b:, 'ms_cache_id', []) ==# cache_id
        let before = s:matches_above()
        let total  = b:ms_cache[-1]
    else
        " if the cache can't be used, recompute
        let before = line('.') ==# 1 ? 0 : s:matches_in_range('1,.-1')
        let total  = before + s:matches_in_range('.,$')
    endif

    " update the cache
    let b:ms_cache    = [line('.'), before, total]
    let b:ms_cache_id = cache_id

    let &l:fen = fen_save
    call winrestview(view)

    return [before + in_line, total]
endfu

fu! s:matches_in_line() abort "{{{1
" Return number of matches before the cursor, on the current line.
    let [line, col] = [line('.'), col('.')]

    norm! 0
    let matches = 0
    let flag    = 'c'
    while search(@/, flag, line) && col('.') <= col
        let matches += 1
        let flag     = ''
    endwhile

    return matches
endfu

fu! s:matches_in_range(range) abort "{{{1
    let marks_save = [getpos("'["), getpos("']")]
    " Why `:keepj`?{{{
    "
    " To prevent  polluting the jumplist.
    " It could matter  when we type `<plug>(ms_prev)`.
    "}}}
    " Why `~`?{{{
    "
    " To prevent the last substitute string (`~`) from being mutated.
    "}}}
    " FIXME: `:s` still mutates the last flags
    let output = execute('keepj '.a:range.'s//~/gen')
    call setpos("'[", marks_save[0])
    call setpos("']", marks_save[1])
    return str2nr(matchstr(output, '\d\+'))
endfu

fu! search#nohls() abort "{{{1
    augroup my_search
        au!
        au CursorMoved,CursorMovedI * set nohlsearch
        au CursorMoved,CursorMovedI * exe 'au! my_search' | aug! my_search
    augroup END
    return ''
endfu

" nohls_on_leave {{{1

" when we do:
"
"     c / pattern cr
"
" `cr` enables 'hls', we need to disable it
fu! search#nohls_on_leave()
    augroup my_search
        au!
        au InsertLeave * set nohls
        au InsertLeave * exe 'au! my_search' | aug! my_search
    augroup END
    " return an empty string, so that the function doesn't insert anything
    return ''
endfu

fu! search#restore_unnamed_register() abort "{{{1
    " restore unnamed register if we've made it mutate
    if exists('s:unnamed_reg_save')
        call call('setreg', s:unnamed_reg_save)
        unlet! s:unnamed_reg_save
    endif
endfu

fu! s:set_hls() abort "{{{1
    " If we don't remove the autocmd, when `n` will be typed, the cursor will
    " move, and 'hls' will be disabled. We want 'hls' to stay enabled even
    " after the `n` motion. Same issue with the motion after a `/` search (not
    " the first one; the next ones). And probably with `gd`, `*`.
    "
    " Besides, during the evaluation of `search#blink()`, `s:blink.tick()`
    " will be called several times, but the condition to install a hl will never
    " be satisfied (it makes sure 'hls' is enabled, to avoid installing the
    " hl, if the cursor has just moved). So, no blinking either.
    sil! au! my_search
    sil! aug! my_search
    set hlsearch
endfu

fu! s:tick(_) abort dict "{{{1
"          │
"          └ when `timer_start()` will call this function, it will send
"            the timer ID

    let self.ticks -= 1

    let active = self.ticks > 0

    " What does the next condition do? {{{
    "
    " PART1:
    " We need the blinking to stop and not go on forever.
    " 2 solutions:
    "
    "     1. use the 'repeat' option of the `timer_start()` function:
    "
    "         call timer_start(self.delay, self.tick, { 'repeat' : 6 })
    "
    "     2. decrement a counter every time `blink.tick()` is called
    "
    " We'll use the 2nd solution, because by adding the counter to the
    " dictionary `s:blink`, we have a single object which includes the whole
    " configuration of the blinking:
    "
    "     - how does it blink?                           s:blink.tick
    "     - how many times does it blink?                s:blink.ticks
    "     - how much time does it wait between 2 ticks?  s:blink.delay
    "
    " It gives us a consistent way to change the configuration of the blinking.
    "
    " This explains the `if active` part of the next condition.
    "
    " PART2:
    " If we move the cursor right after the blinking has begun, we don't want
    " the blinking to go on, because it would follow our cursor (look at the
    " pattern passed to `matchadd()`). Although the effect is only visible if
    " the delay between 2 ticks is big enough (ex: 500 ms).
    "
    " We need to stop the blinking if the cursor moves.
    " How to detect that the cursor is moving?
    " We already have an autocmd listening to the `CursorMoved` event.
    " When our autocmd is fired, 'hlsearch' is disabled.
    " So, if 'hlsearch' is disabled, we should stop the blinking.
    "
    " This explains the `if &hls` part of the next condition.
    "
    " PART3:
    "
    " For a blinking to occur, we need a condition which is satisfied only once
    " out of twice.
    " We could use the output of `blink.delete()` to know whether a hl has
    " just been deleted. And in this case, we could decide to NOT re-install
    " a hl immediately. Otherwise, re-install one.
    "
    " This explains the `if !self.delete()` part of the next condition.
"}}}

    "  (re-)install the hl if:
    "
    "  ┌─ try to delete the hl, and check we haven't been able to do so
    "  │  if we have, we don't want to re-install a hl immediately (only next tick)
    "  │                 ┌─ the cursor hasn't moved
    "  │                 │            ┌─ the blinking is still active
    "  │                 │            │
    if !self.delete() && &hlsearch && active
        "                                1 list describing 1 “position”;              ┐
        "                               `matchaddpos()` can accept up to 8 positions; │
        "                                each position can match:                     │
        "                                                                             │
        "                                    • a whole line                           │
        "                                    • a part of a line                       │
        "                                    • a character                            │
        "                                                                             │
        "                                The column index starts from 1,              │
        "                                like with `col()`. Not from 0.               │
        "                                                                             │
        "                                          ┌──────────────────────────────────┤
        let w:blink_id = matchaddpos('IncSearch', [[line('.'), max([1, col('.')-3]), 6]])
        "                                           │          │                     │
        "                                           │          │                     └ with a length of 6 bytes
        "                                           │          └ begin 3 bytes before cursor
        "                                           └ on the current line
    endif

    " if the blinking still has ticks to process, recall this function later
    if active
        " call `s:blink.tick()` (current function) after `s:blink.delay` ms
        call timer_start(self.delay, self.tick)
        "                            │
        "                            └─ we need `self.key` to be evaluated as a key in a dictionary,
        "                               whose value is a funcref, so don't put quotes around
    endif
endfu
" What does `s:tick()` do? {{{
"
" It cycles between installing and removing the highlighting:
" If the initial numerical value of the variable `s:blink.ticks` is even,
" here's what happens:
"
" ticks = 4   (immediately decremented)
"         3 → install hl
"         2 → remove hl (when evaluating `self.delete()`)
"         1 → install hl
"         0 → remove hl
"
" If it's odd:
"
" ticks = 5
"         4 → install hl
"         3 → remove hl
"         2 → install hl
"         1 → remove hl
"         0 → don't do anything because inactive
"
"}}}
" DON'T make this function anonymous!{{{
"
" Originally, junegunn wrote this function as an anonymous one:
"
"         fu! s:blink.tick()
"             …
"         endfu
"
" It works, but debugging an anonymous function is hard. In particular,
" our `:WTF` command can't show us the location of the error.
" For more info:
"
"     https://github.com/LucHermitte/lh-vim-lib/blob/master/doc/OO.md
"
" Instead, we give it a proper name, and at the end of the script, we assign its
" funcref to `s:blink.tick`.
"
" Same remark for `s:delete()`. Don't make it anonymous.
"}}}

fu! search#toggle_hls(action) abort "{{{1
    if a:action is# 'save'
        let s:hls_on = &hls
        set hls
    else
        if exists('s:hls_on')
            exe 'set '.(s:hls_on ? '' : 'no').'hls'
            unlet! s:hls_on
        endif
    endif
endfu

fu! search#view() abort "{{{1
" make a nice view, by opening folds if any, and by restoring the view if
" it changed but we wanted to stay where we were (happens with `*` and friends)

    let seq = foldclosed('.') !=# -1 ? 'zMzv' : ''

    " What are `s:winline` and `s:windiff`? {{{
    "
    " `s:winline` exists only if we hit `*`, `#` (visual/normal), `g*` or `g#`.
    "
    " NOTE:
    "
    " The goal of `s:windiff` is to restore the state of the window after we
    " search with `*` and friends.
    "
    " When we hit `*`, the rhs is evaluated into the output of `search#wrap_star()`.
    " During the evaluation, the variable `s:winline` is set.
    " The result of the evaluation is (broken on 3 lines to make it more
    " readable):
    "
    "     *<plug>(ms_prev)
    "      <plug>(ms_slash)<plug>(ms_up)<plug>(ms_cr)<plug>(ms_prev)
    "      <plug>(ms_nohls)<plug>(ms_view)<plug>(ms_blink)<plug>(ms_index)
    "
    " What's important to understand here, is that `view()` is called AFTER
    " `search#wrap_star()`. Therefore, `s:winline` is not necessarily
    " the same as the current output of `winline()`, and we can use:
    "
    "     winline() - s:winline
    "
    " … to compute the number of times we have to hit `C-e` or `C-y` to
    " position the current line in the window, so that the state of the window
    " is restored as it was before we hit `*`.
    "}}}

    if exists('s:winline')
        let windiff = winline() - s:winline
        unlet s:winline

        " If `windiff` is positive, it means the current line is further away
        " from the top line of the window, than it was originally.
        " We have to move the window down to restore the original distance
        " between current line and top line.
        " Thus, we use `C-e`. Otherwise, we use `C-y`. Each time we must
        " prefix the key with the right count (± `windiff`).

        let seq .= windiff > 0
               \ ?     windiff."\<c-e>"
               \ : windiff < 0
               \ ?     -windiff."\<c-y>"
               \ :     ''
    endif

    return seq
endfu

fu! search#wrap_gd(is_fwd) abort "{{{1
    call s:set_hls()
    " If we press `gd`  on the 1st occurrence of a  keyword, the highlighting is
    " still not disabled.
    call timer_start(0, {-> search#nohls()})
    return (a:is_fwd ? 'gd' : 'gD')."\<plug>(ms_custom)"
endfu

fu! search#wrap_n(is_fwd) abort "{{{1
    call s:set_hls()

    " We want `n` and `N` to move consistently no matter the direction of the
    " search `/`, or `?`.
    " toggle the value of `n`, `N` if necessary
    let seq = (a:is_fwd ? 'Nn' : 'nN')[v:searchforward]

    " If we change the value of `seq` (`n` to `N` or `N` to `n`), when we perform
    " a backward search we have the error:
    "
    "         E223: recursive mapping
    "
    " Why? Because we are stuck going back and forth between 2 mappings:
    "
    "         echo v:searchforward  →  0
    "
    "         hit `n`  →  wrap_n() returns `N`  →  returns `n`  →  returns `N`  →  …
    "
    " To prevent being stuck in an endless expansion, use non-recursive versions
    " of `n` and `N`.
    let seq = (seq is# 'n' ? "\<plug>(ms_n)" : "\<plug>(ms_N)")

    call timer_start(0, {-> v:errmsg[:4] is# 'E486:' ? search#nohls() : '' })

    return seq."\<plug>(ms_custom)"

    " Vim doesn't wait for everything to be expanded, before beginning typing.
    " As soon as it finds something which can't be remapped, it types it.
    " And `n` can't be remapped, because of `:h recursive_mapping`:
    "
    "     If the {rhs} starts with {lhs}, the first character is not mapped
    "     again (this is Vi compatible).
    "
    " Therefore, here, Vim types `n` immediately, BEFORE processing the rest
    " of the mapping.
    " This explains why Vim FIRST moves the cursor with n, THEN makes the
    " current position blink.
    " If Vim expanded everything before even beginning typing, the blinking
    " would occur at the current position, instead of the next match.
endfu

fu! search#wrap_star(seq) abort "{{{1
    " if the function is invoked from visual mode, it will copy the visual selection,
    " because `a:seq` begins with the key `y`;
    " in this case, we save the unnamed register to restore it later
    if index(['v', 'V', "\<c-v>"], mode()) >= 0
        let s:unnamed_reg_save = ['"', getreg('"'), getregtype('"')]
    endif

    " `winline()` returns the position of the current line from the top line of
    " the window. The position / index of the latter is 1.
    let s:winline = winline()

    call s:set_hls()

    " We have an autocmd which invokes  `after_slash()` when we leave the search
    " command-line.  It needs to be to  temporarily disabled while we type `/ up
    " cr`, otherwise it would badly interfere.
    let s:after_slash = 0

    " If we press * on nothing, it  raises E348 or E349, and Vim highlights last
    " search pattern. But because of the error, Vim didn't finish processing the
    " mapping.   Therefore, the  highlighting is  not cleared  when we  move the
    " cursor. Make sure it is.
    "
    " Also, make sure to re-enable the invokation of `after_slash()` after a `/`
    " search.
    call timer_start(0, { -> v:errmsg[:4] =~# '\vE%(348|349):'
    \                      ?       search#nohls()
    \                            + execute('let s:after_slash = 1')
    \                      :       '' })

    " Why     `\<plug>(ms_slash)\<plug>(ms_up)\<plug>(ms_cr)…`?{{{
    "
    " By default `*` is stupid, it ignores 'smartcase'.
    " To workaround this issue, we type this:
    "         / up cr c-o
    "
    " It searches for the same pattern than `*` but with `/`.
    " The latter takes 'smartcase' into account.
    "
    " In visual mode, we already do this, so, it's not necessary from there.
    " But we let the function do it again anyway, because it doesn't cause any issue.
    " If it causes an issue, we should test the current mode, and add the
    " keys on the last 2 lines only from normal mode.
"}}}
    return a:seq."\<plug>(ms_restore_unnamed_register)"
    \           ."\<plug>(ms_prev)"
    \           ."\<plug>(ms_slash)\<plug>(ms_up)\<plug>(ms_cr)\<plug>(ms_prev)"
    \           ."\<plug>(ms_re-enable_after_slash)"
    \           ."\<plug>(ms_custom)"
endfu

" Variables {{{1

" `s:blink` must be initialized AFTER defining the functions
" `s:tick()` and `s:delete()`.
let s:blink = { 'ticks': 4, 'delay': 50 }
let s:blink.tick   = function('s:tick')
let s:blink.delete = function('s:delete')
