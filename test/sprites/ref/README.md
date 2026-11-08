# Reference copy for the lockstep test

`sprite_fetch_ref.v` is `rtl/sprite_fetch.v` as it was before its scheduler
side changed (retro-hw main at 3453084: `mem_deadline` output,
combinational `mem_urgent`, `SWAP_BYTES`, no `AW`), with the module renamed.
It is the oracle for `tb_lock_sprite.v` and is not built into anything.
