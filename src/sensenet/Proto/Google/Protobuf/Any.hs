{- This file was auto-generated from google/protobuf/any.proto by the proto-lens-protoc program. -}
{-# LANGUAGE ScopedTypeVariables, DataKinds, TypeFamilies, UndecidableInstances, GeneralizedNewtypeDeriving, MultiParamTypeClasses, FlexibleContexts, FlexibleInstances, PatternSynonyms, MagicHash, NoImplicitPrelude, DataKinds, BangPatterns, TypeApplications, OverloadedStrings, DerivingStrategies#-}
{-# OPTIONS_GHC -Wno-unused-imports#-}
{-# OPTIONS_GHC -Wno-duplicate-exports#-}
{-# OPTIONS_GHC -Wno-dodgy-exports#-}
module Proto.Google.Protobuf.Any (
        Any()
    ) where
import qualified Data.ProtoLens.Runtime.Control.DeepSeq as Control.DeepSeq
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Prism as Data.ProtoLens.Prism
import qualified Data.ProtoLens.Runtime.Prelude as Prelude
import qualified Data.ProtoLens.Runtime.Data.Int as Data.Int
import qualified Data.ProtoLens.Runtime.Data.Monoid as Data.Monoid
import qualified Data.ProtoLens.Runtime.Data.Word as Data.Word
import qualified Data.ProtoLens.Runtime.Data.ProtoLens as Data.ProtoLens
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Encoding.Bytes as Data.ProtoLens.Encoding.Bytes
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Encoding.Growing as Data.ProtoLens.Encoding.Growing
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Encoding.Parser.Unsafe as Data.ProtoLens.Encoding.Parser.Unsafe
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Encoding.Wire as Data.ProtoLens.Encoding.Wire
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Field as Data.ProtoLens.Field
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Message.Enum as Data.ProtoLens.Message.Enum
import qualified Data.ProtoLens.Runtime.Data.ProtoLens.Service.Types as Data.ProtoLens.Service.Types
import qualified Data.ProtoLens.Runtime.Lens.Family2 as Lens.Family2
import qualified Data.ProtoLens.Runtime.Lens.Family2.Unchecked as Lens.Family2.Unchecked
import qualified Data.ProtoLens.Runtime.Data.Text as Data.Text
import qualified Data.ProtoLens.Runtime.Data.Map as Data.Map
import qualified Data.ProtoLens.Runtime.Data.ByteString as Data.ByteString
import qualified Data.ProtoLens.Runtime.Data.ByteString.Char8 as Data.ByteString.Char8
import qualified Data.ProtoLens.Runtime.Data.Text.Encoding as Data.Text.Encoding
import qualified Data.ProtoLens.Runtime.Data.Vector as Data.Vector
import qualified Data.ProtoLens.Runtime.Data.Vector.Generic as Data.Vector.Generic
import qualified Data.ProtoLens.Runtime.Data.Vector.Unboxed as Data.Vector.Unboxed
import qualified Data.ProtoLens.Runtime.Text.Read as Text.Read
{- | Fields :
     
         * 'Proto.Google.Protobuf.Any_Fields.typeUrl' @:: Lens' Any Data.Text.Text@
         * 'Proto.Google.Protobuf.Any_Fields.value' @:: Lens' Any Data.ByteString.ByteString@ -}
data Any
  = Any'_constructor {_Any'typeUrl :: !Data.Text.Text,
                      _Any'value :: !Data.ByteString.ByteString,
                      _Any'_unknownFields :: !Data.ProtoLens.FieldSet}
  deriving stock (Prelude.Eq, Prelude.Ord)
instance Prelude.Show Any where
  showsPrec _ __x __s
    = Prelude.showChar
        '{'
        (Prelude.showString
           (Data.ProtoLens.showMessageShort __x) (Prelude.showChar '}' __s))
instance Data.ProtoLens.Field.HasField Any "typeUrl" Data.Text.Text where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _Any'typeUrl (\ x__ y__ -> x__ {_Any'typeUrl = y__}))
        Prelude.id
instance Data.ProtoLens.Field.HasField Any "value" Data.ByteString.ByteString where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _Any'value (\ x__ y__ -> x__ {_Any'value = y__}))
        Prelude.id
instance Data.ProtoLens.Message Any where
  messageName _ = Data.Text.pack "google.protobuf.Any"
  packedMessageDescriptor _
    = "\n\
      \\ETXAny\DC2\EM\n\
      \\btype_url\CAN\SOH \SOH(\tR\atypeUrl\DC2\DC4\n\
      \\ENQvalue\CAN\STX \SOH(\fR\ENQvalue"
  packedFileDescriptor _ = packedFileDescriptor
  fieldsByTag
    = let
        typeUrl__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "type_url"
              (Data.ProtoLens.ScalarField Data.ProtoLens.StringField ::
                 Data.ProtoLens.FieldTypeDescriptor Data.Text.Text)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional (Data.ProtoLens.Field.field @"typeUrl")) ::
              Data.ProtoLens.FieldDescriptor Any
        value__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "value"
              (Data.ProtoLens.ScalarField Data.ProtoLens.BytesField ::
                 Data.ProtoLens.FieldTypeDescriptor Data.ByteString.ByteString)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional (Data.ProtoLens.Field.field @"value")) ::
              Data.ProtoLens.FieldDescriptor Any
      in
        Data.Map.fromList
          [(Data.ProtoLens.Tag 1, typeUrl__field_descriptor),
           (Data.ProtoLens.Tag 2, value__field_descriptor)]
  unknownFields
    = Lens.Family2.Unchecked.lens
        _Any'_unknownFields (\ x__ y__ -> x__ {_Any'_unknownFields = y__})
  defMessage
    = Any'_constructor
        {_Any'typeUrl = Data.ProtoLens.fieldDefault,
         _Any'value = Data.ProtoLens.fieldDefault, _Any'_unknownFields = []}
  parseMessage
    = let
        loop :: Any -> Data.ProtoLens.Encoding.Bytes.Parser Any
        loop x
          = do end <- Data.ProtoLens.Encoding.Bytes.atEnd
               if end then
                   do (let missing = []
                       in
                         if Prelude.null missing then
                             Prelude.return ()
                         else
                             Prelude.fail
                               ((Prelude.++)
                                  "Missing required fields: "
                                  (Prelude.show (missing :: [Prelude.String]))))
                      Prelude.return
                        (Lens.Family2.over
                           Data.ProtoLens.unknownFields (\ !t -> Prelude.reverse t) x)
               else
                   do tag <- Data.ProtoLens.Encoding.Bytes.getVarInt
                      case tag of
                        10
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (do len <- Data.ProtoLens.Encoding.Bytes.getVarInt
                                           Data.ProtoLens.Encoding.Bytes.getText
                                             (Prelude.fromIntegral len))
                                       "type_url"
                                loop (Lens.Family2.set (Data.ProtoLens.Field.field @"typeUrl") y x)
                        18
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (do len <- Data.ProtoLens.Encoding.Bytes.getVarInt
                                           Data.ProtoLens.Encoding.Bytes.getBytes
                                             (Prelude.fromIntegral len))
                                       "value"
                                loop (Lens.Family2.set (Data.ProtoLens.Field.field @"value") y x)
                        wire
                          -> do !y <- Data.ProtoLens.Encoding.Wire.parseTaggedValueFromWire
                                        wire
                                loop
                                  (Lens.Family2.over
                                     Data.ProtoLens.unknownFields (\ !t -> (:) y t) x)
      in
        (Data.ProtoLens.Encoding.Bytes.<?>)
          (do loop Data.ProtoLens.defMessage) "Any"
  buildMessage
    = \ _x
        -> (Data.Monoid.<>)
             (let
                _v = Lens.Family2.view (Data.ProtoLens.Field.field @"typeUrl") _x
              in
                if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                    Data.Monoid.mempty
                else
                    (Data.Monoid.<>)
                      (Data.ProtoLens.Encoding.Bytes.putVarInt 10)
                      ((Prelude..)
                         (\ bs
                            -> (Data.Monoid.<>)
                                 (Data.ProtoLens.Encoding.Bytes.putVarInt
                                    (Prelude.fromIntegral (Data.ByteString.length bs)))
                                 (Data.ProtoLens.Encoding.Bytes.putBytes bs))
                         Data.Text.Encoding.encodeUtf8 _v))
             ((Data.Monoid.<>)
                (let
                   _v = Lens.Family2.view (Data.ProtoLens.Field.field @"value") _x
                 in
                   if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                       Data.Monoid.mempty
                   else
                       (Data.Monoid.<>)
                         (Data.ProtoLens.Encoding.Bytes.putVarInt 18)
                         ((\ bs
                             -> (Data.Monoid.<>)
                                  (Data.ProtoLens.Encoding.Bytes.putVarInt
                                     (Prelude.fromIntegral (Data.ByteString.length bs)))
                                  (Data.ProtoLens.Encoding.Bytes.putBytes bs))
                            _v))
                (Data.ProtoLens.Encoding.Wire.buildFieldSet
                   (Lens.Family2.view Data.ProtoLens.unknownFields _x)))
instance Control.DeepSeq.NFData Any where
  rnf
    = \ x__
        -> Control.DeepSeq.deepseq
             (_Any'_unknownFields x__)
             (Control.DeepSeq.deepseq
                (_Any'typeUrl x__) (Control.DeepSeq.deepseq (_Any'value x__) ()))
packedFileDescriptor :: Data.ByteString.ByteString
packedFileDescriptor
  = "\n\
    \\EMgoogle/protobuf/any.proto\DC2\SIgoogle.protobuf\"6\n\
    \\ETXAny\DC2\EM\n\
    \\btype_url\CAN\SOH \SOH(\tR\atypeUrl\DC2\DC4\n\
    \\ENQvalue\CAN\STX \SOH(\fR\ENQvalueBv\n\
    \\DC3com.google.protobufB\bAnyProtoP\SOHZ,google.golang.org/protobuf/types/known/anypb\162\STX\ETXGPB\170\STX\RSGoogle.Protobuf.WellKnownTypesJ\233(\n\
    \\ACK\DC2\EOT\RS\NULi\SOH\n\
    \\204\f\n\
    \\SOH\f\DC2\ETX\RS\NUL\DC22\193\f Protocol Buffers - Google's data interchange format\n\
    \ Copyright 2008 Google Inc.  All rights reserved.\n\
    \ https://developers.google.com/protocol-buffers/\n\
    \\n\
    \ Redistribution and use in source and binary forms, with or without\n\
    \ modification, are permitted provided that the following conditions are\n\
    \ met:\n\
    \\n\
    \     * Redistributions of source code must retain the above copyright\n\
    \ notice, this list of conditions and the following disclaimer.\n\
    \     * Redistributions in binary form must reproduce the above\n\
    \ copyright notice, this list of conditions and the following disclaimer\n\
    \ in the documentation and/or other materials provided with the\n\
    \ distribution.\n\
    \     * Neither the name of Google Inc. nor the names of its\n\
    \ contributors may be used to endorse or promote products derived from\n\
    \ this software without specific prior written permission.\n\
    \\n\
    \ THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS\n\
    \ \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT\n\
    \ LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR\n\
    \ A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT\n\
    \ OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,\n\
    \ SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT\n\
    \ LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,\n\
    \ DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY\n\
    \ THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT\n\
    \ (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE\n\
    \ OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.\n\
    \\n\
    \\b\n\
    \\SOH\STX\DC2\ETX \NUL\CAN\n\
    \\b\n\
    \\SOH\b\DC2\ETX\"\NULC\n\
    \\t\n\
    \\STX\b\v\DC2\ETX\"\NULC\n\
    \\b\n\
    \\SOH\b\DC2\ETX#\NUL,\n\
    \\t\n\
    \\STX\b\SOH\DC2\ETX#\NUL,\n\
    \\b\n\
    \\SOH\b\DC2\ETX$\NUL)\n\
    \\t\n\
    \\STX\b\b\DC2\ETX$\NUL)\n\
    \\b\n\
    \\SOH\b\DC2\ETX%\NUL\"\n\
    \\t\n\
    \\STX\b\n\
    \\DC2\ETX%\NUL\"\n\
    \\b\n\
    \\SOH\b\DC2\ETX&\NUL!\n\
    \\t\n\
    \\STX\b$\DC2\ETX&\NUL!\n\
    \\b\n\
    \\SOH\b\DC2\ETX'\NUL;\n\
    \\t\n\
    \\STX\b%\DC2\ETX'\NUL;\n\
    \\220\f\n\
    \\STX\EOT\NUL\DC2\EOTG\NULi\SOH\SUB\207\f `Any` contains an arbitrary serialized protocol buffer message along with a\n\
    \ URL that describes the type of the serialized message.\n\
    \\n\
    \ In its binary encoding, an `Any` is an ordinary message; but in other wire\n\
    \ forms like JSON, it has a special encoding. The format of the type URL is\n\
    \ described on the `type_url` field.\n\
    \\n\
    \ Protobuf APIs provide utilities to interact with `Any` values:\n\
    \\n\
    \ - A 'pack' operation accepts a message and constructs a generic `Any` wrapper\n\
    \   around it.\n\
    \ - An 'unpack' operation reads the content of an `Any` message, either into an\n\
    \   existing message or a new one. Unpack operations must check the type of the\n\
    \   value they unpack against the declared `type_url`.\n\
    \ - An 'is' operation decides whether an `Any` contains a message of the given\n\
    \   type, i.e. whether it can 'unpack' that type.\n\
    \\n\
    \ The JSON format representation of an `Any` follows one of these cases:\n\
    \\n\
    \ - For types without special-cased JSON encodings, the JSON format\n\
    \   representation of the `Any` is the same as that of the message, with an\n\
    \   additional `@type` field which contains the type URL.\n\
    \ - For types with special-cased JSON encodings (typically called 'well-known'\n\
    \   types, listed in https://protobuf.dev/programming-guides/json/#any), the\n\
    \   JSON format representation has a key `@type` which contains the type URL\n\
    \   and a key `value` which contains the JSON-serialized value.\n\
    \\n\
    \ The text format representation of an `Any` is like a message with one field\n\
    \ whose name is the type URL in brackets. For example, an `Any` containing a\n\
    \ `foo.Bar` message may be written `[type.googleapis.com/foo.Bar] { a: 2 }`.\n\
    \\n\
    \\n\
    \\n\
    \\ETX\EOT\NUL\SOH\DC2\ETXG\b\v\n\
    \\246\f\n\
    \\EOT\EOT\NUL\STX\NUL\DC2\ETXe\STX\SYN\SUB\232\f Identifies the type of the serialized Protobuf message with a URI reference\n\
    \ consisting of a prefix ending in a slash and the fully-qualified type name.\n\
    \\n\
    \ Example: type.googleapis.com/google.protobuf.StringValue\n\
    \\n\
    \ This string must contain at least one `/` character, and the content after\n\
    \ the last `/` must be the fully-qualified name of the type in canonical\n\
    \ form, without a leading dot. Do not write a scheme on these URI references\n\
    \ so that clients do not attempt to contact them.\n\
    \\n\
    \ The prefix is arbitrary and Protobuf implementations are expected to\n\
    \ simply strip off everything up to and including the last `/` to identify\n\
    \ the type. `type.googleapis.com/` is a common default prefix that some\n\
    \ legacy implementations require. This prefix does not indicate the origin of\n\
    \ the type, and URIs containing it are not expected to respond to any\n\
    \ requests.\n\
    \\n\
    \ All type URL strings must be legal URI references with the additional\n\
    \ restriction (for the text format) that the content of the reference\n\
    \ must consist only of alphanumeric characters, percent-encoded escapes, and\n\
    \ characters in the following set (not including the outer backticks):\n\
    \ `/-.~_!$&()*+,;=`. Despite our allowing percent encodings, implementations\n\
    \ should not unescape them to prevent confusion with existing parsers. For\n\
    \ example, `type.googleapis.com%2FFoo` should be rejected.\n\
    \\n\
    \ In the original design of `Any`, the possibility of launching a type\n\
    \ resolution service at these type URLs was considered but Protobuf never\n\
    \ implemented one and considers contacting these URLs to be problematic and\n\
    \ a potential security issue. Do not attempt to contact type URLs.\n\
    \\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\NUL\ENQ\DC2\ETXe\STX\b\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\NUL\SOH\DC2\ETXe\t\DC1\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\NUL\ETX\DC2\ETXe\DC4\NAK\n\
    \P\n\
    \\EOT\EOT\NUL\STX\SOH\DC2\ETXh\STX\DC2\SUBC Holds a Protobuf serialization of the type described by type_url.\n\
    \\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\SOH\ENQ\DC2\ETXh\STX\a\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\SOH\SOH\DC2\ETXh\b\r\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\SOH\ETX\DC2\ETXh\DLE\DC1b\ACKproto3"