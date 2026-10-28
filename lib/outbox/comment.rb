# frozen_string_literal: true

require "json"
require "digest"

module Outbox
  # A review comment, in git-appraise's format
  # (https://github.com/google/git-appraise, schema/comment.json), so that
  # anything that reads that can read these. Each is one line of JSON in a
  # git note under Repo::COMMENTS_REF, on the staged tip it was written
  # about:
  #
  #   {"timestamp":"1761654000","author":"jhawthorn","location":{"commit":"<sha>",
  #    "path":"lib/a.rb","range":{"startLine":3,"endLine":5}},"description":"..."}
  #
  # location is absent for a comment on the whole review, range for one on
  # a whole file. A line range is in the file as it is in location.commit:
  # the staged tip for lines the change has, upstream's tip for lines it
  # removes. resolved is git-appraise's verdict: true on the comment an
  # approval leaves, false on a discard's, absent on anything else.
  class Comment
    attr_reader :timestamp, :author, :description, :commit, :path, :start_line, :end_line, :resolved, :id

    def initialize(author:, description:, timestamp: Time.now.to_i.to_s, commit: nil, path: nil,
                   start_line: nil, end_line: nil, resolved: nil, id: nil)
      @timestamp = timestamp
      @author = author
      @description = description
      @commit = commit
      @path = path
      @start_line = start_line
      @end_line = end_line
      @resolved = resolved
      @id = id
    end

    # One comment from one line of a note, or nil when the line is not one.
    # The id is what git-appraise calls a comment by: the sha1 of its line.
    def self.parse(line)
      h = JSON.parse(line)
      return nil unless h.is_a?(Hash)
      location = h["location"].is_a?(Hash) ? h["location"] : {}
      range = location["range"].is_a?(Hash) ? location["range"] : {}
      start_line = range["startLine"].is_a?(Integer) ? range["startLine"] : nil
      end_line = range["endLine"].is_a?(Integer) && range["endLine"].positive? ? range["endLine"] : start_line
      new(timestamp: h["timestamp"].to_s, author: h["author"].to_s, description: h["description"].to_s,
          commit: location["commit"]&.to_s, path: location["path"]&.to_s,
          start_line:, end_line:, resolved: h["resolved"] == true || h["resolved"] == false ? h["resolved"] : nil,
          id: Digest::SHA1.hexdigest(line.chomp))
    rescue JSON::ParserError
      nil
    end

    # Every comment in a note, oldest first, as git-appraise orders them:
    # by timestamp, and in the note's order for a tie.
    def self.parse_all(text)
      text.each_line.filter_map { |l| parse(l) unless l.strip.empty? }.each_with_index
        .sort_by { |c, i| [c.timestamp.to_i, i] }.map(&:first)
    end

    def to_json_line
      h = { "timestamp" => timestamp, "author" => author }
      if commit
        location = { "commit" => commit }
        location["path"] = path if path
        if start_line
          location["range"] = { "startLine" => start_line }
          location["range"]["endLine"] = end_line if end_line && end_line != start_line
        end
        h["location"] = location
      end
      h["description"] = description
      h["resolved"] = resolved unless resolved.nil?
      JSON.generate(h)
    end

    def time = Time.at(timestamp.to_i)
    def line? = !start_line.nil?
    def file? = !path.nil?
    def approval? = resolved == true
    def rejection? = resolved == false
  end
end
