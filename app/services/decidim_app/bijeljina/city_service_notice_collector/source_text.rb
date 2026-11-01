# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module CityServiceNoticeCollector
      # Byte-level normalisation of a fetched text document before any parser
      # sees it.
      #
      # Providers truncate excerpts by byte length and leave a lone UTF-8 lead
      # byte inside an otherwise valid, correctly declared UTF-8 page (the
      # Sistem 48 archive and the Komunalac listing, captured 2026-09-13).
      # Re-reading such a page as Windows-1250 because "it is not valid UTF-8"
      # is what turned 13 of 15 "Prijava riješena" labels into
      # "Prijava rijeĹˇena" on 2026-09-09. The rule here: honour the declared
      # charset, repair only the provably broken sequences, never reinterpret a
      # UTF-8 document as a whole, and leave binary documents byte-for-byte
      # because their checksums are evidence.
      module SourceText
        TEXT_TYPES = %r{\A(?:text/|application/(?:xml|rss\+xml|atom\+xml|xhtml\+xml|json|javascript))}i
        BINARY_TYPES = %r{\Aapplication/(?:pdf|octet-stream|zip|x-)}i
        CHARSET_PARAM = /charset\s*=\s*"?([A-Za-z0-9_.:-]+)/i
        META_CHARSET = /<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9_.:-]+)/i
        XML_ENCODING = /\A\s*<\?xml[^>]*encoding\s*=\s*["']([A-Za-z0-9_.:-]+)["']/i
        HEAD_BYTES = 4096

        module_function

        # Returns a valid UTF-8 string for text documents; anything else comes
        # back untouched. +charset+ is the transport header's parameter when the
        # caller kept it separately from the media type.
        def normalize(body, content_type: "", charset: nil)
          body = body.to_s
          return body unless text?(body, content_type)

          encoding = declared_charset(body, content_type, charset:)
          if utf8?(encoding)
            text = body.dup.force_encoding(Encoding::UTF_8)
            text.valid_encoding? ? text : text.scrub
          else
            body.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
          end
        end

        def text?(body, content_type)
          bytes = body.b
          return false if bytes.start_with?("%PDF-")
          return true if content_type.to_s.match?(TEXT_TYPES)
          return false if content_type.to_s.match?(BINARY_TYPES)

          bytes.byteslice(0, 512).to_s.sub(/\A\xEF\xBB\xBF/n, "").lstrip.start_with?("<")
        end

        # The transport charset wins; otherwise the document's own XML or meta
        # declaration; otherwise UTF-8. An unknown name is UTF-8, never a guess.
        def declared_charset(body, content_type, charset: nil)
          name = charset.presence || content_type.to_s[CHARSET_PARAM, 1]
          head = body.b.byteslice(0, HEAD_BYTES).to_s
          name ||= head[XML_ENCODING, 1] || head[META_CHARSET, 1]
          (name && Encoding.find(name)) || Encoding::UTF_8
        rescue ArgumentError
          Encoding::UTF_8
        end

        def utf8?(encoding)
          [Encoding::UTF_8, Encoding::US_ASCII].include?(encoding)
        end
      end
    end
  end
end
