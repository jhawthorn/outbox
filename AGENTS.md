# Notes for agents working in this repo

- **Sinatra settings** (`set :foo` / `settings.foo`) are an anti-feature. Use them only
  where Sinatra itself requires one, such as `views` or `public_folder`. Anything of our
  own goes in a constant, a method, or an argument. Never add a setting to make something
  injectable for a test.
- **No Rust-backed gems.** Nothing built on magnus or rb_sys. Plain Ruby or a C extension.
- **No rouge.** The diff viewer highlights in the browser with @pierre/diffs (Shiki).
- **Plain classes, not Struct or Data.**
- **Run subprocesses with separate arguments** (`Open3.capture3("git", "fetch", remote)`),
  not a command string. Shellwords only where a shell string is genuinely required.
