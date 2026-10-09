# frozen_string_literal: true

# Single process only. The Hub, its per-repo Ractors, and all job status
# live in this process; cluster mode would duplicate them per worker.
workers 0
threads 1, 8
