# typed: strict
# frozen_string_literal: true

module Hallmark
  class Watch
    # Tails the stamp files of one run in a directory
    # (`stamps-<run>-<pid>.jsonl`, `Sinks::File`): the run named, else the
    # newest when the first file appears, kept from then on. A file a newly
    # forked worker starts is picked up at the next poll. Each file is read
    # from where the last poll stopped, complete lines only: a partial last
    # line waits for its newline. A path to one file tails that file.
    class FileTail
      # `run` is the run tailed: the one named, or the one found first; nil
      # before then.
      attr_reader :path, :run

      def initialize(path, run: nil)
        @path = path.to_s
        @run = run
        @offsets = {}
      end

      def blocking? = false

      def description = "#{@path}#{" (run #{@run})" if @run}"

      # The complete lines written since the last poll.
      def poll = files.flat_map { |file| read(file) }

      private

      def files
        return StampSet.files(@path) unless File.directory?(@path)

        run = @run ||= StampSet.run_of(@path)
        run ? StampSet.files(@path, run: run) : []
      end

      # A file shorter than what was read was truncated or replaced, so it
      # is read again from the start.
      def read(file)
        offset = @offsets.fetch(file, 0)
        size = File.size(file)
        offset = 0 if size < offset
        return [] if size == offset

        chunk = File.open(file, "rb") do |io|
          io.seek(offset)
          io.read(size - offset).to_s
        end
        last = chunk.rindex("\n")
        return [] unless last

        @offsets[file] = offset + last + 1
        chunk[0, last].to_s.force_encoding(Encoding::UTF_8).split("\n")
      rescue Errno::ENOENT
        @offsets.delete(file)
        []
      end
    end
  end
end
