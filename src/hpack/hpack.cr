require "http/headers"
require "./huffman"
require "./static_table"
require "./dynamic_table"

module HTTP2
  module HPACK
    @[Flags]
    enum Indexing : UInt8
      INDEXED = 128_u8
      ALWAYS = 64_u8
      NEVER = 16_u8
      NONE = 0_u8
    end

    class Error < Exception
    end

    class SliceReader
      getter offset : Int32
      getter bytes : Slice(UInt8)

      def initialize(@bytes : Slice(UInt8))
        @offset = 0
      end

      def done?
        offset >= bytes.size
      end

      def current_byte
        bytes[offset]
      end

      def read_byte
        current_byte.tap { @offset += 1 }
      end

      def read(count)
        bytes[offset, count].tap { @offset += count }
      end
    end

    class Decoder
      private getter! reader : SliceReader
      getter table : DynamicTable

      def initialize(max_table_size = 4096)
        @table = DynamicTable.new(max_table_size)
      end

      def decode(bytes)
        @reader = SliceReader.new(bytes)
        headers = HTTP::Headers.new

        until reader.done?
          if reader.current_byte.bit(7) == 1           # 1.......  indexed
            index = integer(7)
            raise Error.new("invalid index: 0") if index == 0
            headers.add(*indexed(index))

          elsif reader.current_byte.bit(6) == 1        # 01......  literal with incremental indexing
            index = integer(6)
            name = index == 0 ? string : indexed(index).first
            value = string
            headers.add(name, value)
            table.add(name, value)

          elsif reader.current_byte.bit(5) == 1        # 001.....  table max size update
            table.resize(integer(5))

          elsif reader.current_byte.bit(4) == 1        # 0001....  literal never indexed
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            headers.add(name, string)
            # TODO: retain the never_indexed property

          else                                         # 0000....  literal without indexing
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            headers.add(name, string)
          end
        end

        headers
      end

      protected def indexed(index)
        if index < STATIC_TABLE_SIZE
          return STATIC_TABLE[index - 1]
        end

        if header = table[index - STATIC_TABLE_SIZE - 1]?
          return header
        end

        raise Error.new("invalid index: #{index}")
      end

      protected def integer(n)
        integer = reader.read_byte & (0xff >> (8 - n))
        n2 = 2 ** n - 1
        return integer.to_i if integer < n2

        loop do |m|
          # TODO: raise if integer grows over limit
          byte = reader.read_byte
          integer = integer + (byte & 127) * 2 ** (m * 7)
          break unless byte.bit(7) == 1
        end

        integer.to_i
      end

      protected def string
        huffman = reader.current_byte.bit(7) == 1
        length = integer(7)
        bytes = reader.read(length)

        if huffman
          HPACK.huffman.decode(bytes)
        else
          String.new(bytes)
        end
      end
    end

    class Encoder
      # TODO: allow per header name/value indexing configuration
      # TODO: allow per header name/value huffman encoding configuration
      # TODO: huffman encoding

      private getter! writer : IO
      getter table : DynamicTable
      property default_indexing : Indexing

      def initialize(indexing = Indexing::NONE, max_table_size = 4096)
        @default_indexing = indexing
        @table = DynamicTable.new(max_table_size)
      end

      def encode(headers : HTTP::Headers, indexing = default_indexing)
        @writer = MemoryIO.new

        headers.each do |name, values|
          values.each do |value|
            if header = indexed(name, value)
              if header[1]
                integer(header[0], 7, prefix: Indexing::INDEXED)
              elsif indexing == Indexing::ALWAYS
                integer(header[0], 6, prefix: Indexing::ALWAYS)
                string(value)
                table.add(name, value)
              else
                integer(header[0], 4, prefix: Indexing::NONE)
                string(value)
              end
            else
              case indexing
              when Indexing::ALWAYS
                table.add(name, value)
                writer.write_byte(Indexing::ALWAYS.value)
              when Indexing::NEVER
                writer.write_byte(Indexing::NEVER.value)
              else
                writer.write_byte(Indexing::NONE.value)
              end
              string(name)
              string(value)
            end
          end
        end

        writer.to_slice
      end

      protected def indexed(name, value)
        # OPTIMIZE: use a cached { name => { value => index } } struct (?)
        idx = nil

        STATIC_TABLE.each_with_index do |header, index|
          if header[0] == name
            if header[1] == value
              return {index + 1, value}
            else
              idx ||= index + 1
            end
          end
        end

        table.each_with_index do |header, index|
          if header[0] == name
            if header[1] == value
              return {index + STATIC_TABLE_SIZE + 1, value}
            #else
            #  idx ||= index + 1
            end
          end
        end

        if idx
          {idx, nil}
        end
      end

      protected def integer(integer : Int32, n, prefix = 0_u8)
        n2 = 2 ** n - 1

        if integer <= n2
          writer.write_byte(integer.to_u8 | prefix.to_u8)
          return
        end

        writer.write_byte(n2.to_u8 | prefix.to_u8)
        integer -= n2

        while integer >= 128
          writer.write_byte(((integer % 128) + 128).to_u8)
          integer /= 128
        end

        writer.write_byte(integer.to_u8)
      end

      protected def string(string : String, huffman = false)
        if huffman
          raise "HPACK::Encoder doesn't support Huffman encoding"
          #integer(string.bytesize, 7, prefix: 128)
          #writer << HPACK.huffman.encode(string)
        else
          integer(string.bytesize, 7)
          writer << string
        end
      end
    end
  end
end