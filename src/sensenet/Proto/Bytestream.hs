{- This file was auto-generated from bytestream.proto by the proto-lens-protoc program. -}
{-# LANGUAGE ScopedTypeVariables, DataKinds, TypeFamilies, UndecidableInstances, GeneralizedNewtypeDeriving, MultiParamTypeClasses, FlexibleContexts, FlexibleInstances, PatternSynonyms, MagicHash, NoImplicitPrelude, DataKinds, BangPatterns, TypeApplications, OverloadedStrings, DerivingStrategies#-}
{-# OPTIONS_GHC -Wno-unused-imports#-}
{-# OPTIONS_GHC -Wno-duplicate-exports#-}
{-# OPTIONS_GHC -Wno-dodgy-exports#-}
module Proto.Bytestream (
        ByteStream(..), ReadRequest(), ReadResponse(), WriteRequest(),
        WriteResponse()
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
     
         * 'Proto.Bytestream_Fields.resourceName' @:: Lens' ReadRequest Data.Text.Text@
         * 'Proto.Bytestream_Fields.readOffset' @:: Lens' ReadRequest Data.Int.Int64@
         * 'Proto.Bytestream_Fields.readLimit' @:: Lens' ReadRequest Data.Int.Int64@ -}
data ReadRequest
  = ReadRequest'_constructor {_ReadRequest'resourceName :: !Data.Text.Text,
                              _ReadRequest'readOffset :: !Data.Int.Int64,
                              _ReadRequest'readLimit :: !Data.Int.Int64,
                              _ReadRequest'_unknownFields :: !Data.ProtoLens.FieldSet}
  deriving stock (Prelude.Eq, Prelude.Ord)
instance Prelude.Show ReadRequest where
  showsPrec _ __x __s
    = Prelude.showChar
        '{'
        (Prelude.showString
           (Data.ProtoLens.showMessageShort __x) (Prelude.showChar '}' __s))
instance Data.ProtoLens.Field.HasField ReadRequest "resourceName" Data.Text.Text where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _ReadRequest'resourceName
           (\ x__ y__ -> x__ {_ReadRequest'resourceName = y__}))
        Prelude.id
instance Data.ProtoLens.Field.HasField ReadRequest "readOffset" Data.Int.Int64 where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _ReadRequest'readOffset
           (\ x__ y__ -> x__ {_ReadRequest'readOffset = y__}))
        Prelude.id
instance Data.ProtoLens.Field.HasField ReadRequest "readLimit" Data.Int.Int64 where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _ReadRequest'readLimit
           (\ x__ y__ -> x__ {_ReadRequest'readLimit = y__}))
        Prelude.id
instance Data.ProtoLens.Message ReadRequest where
  messageName _ = Data.Text.pack "google.bytestream.ReadRequest"
  packedMessageDescriptor _
    = "\n\
      \\vReadRequest\DC2#\n\
      \\rresource_name\CAN\SOH \SOH(\tR\fresourceName\DC2\US\n\
      \\vread_offset\CAN\STX \SOH(\ETXR\n\
      \readOffset\DC2\GS\n\
      \\n\
      \read_limit\CAN\ETX \SOH(\ETXR\treadLimit"
  packedFileDescriptor _ = packedFileDescriptor
  fieldsByTag
    = let
        resourceName__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "resource_name"
              (Data.ProtoLens.ScalarField Data.ProtoLens.StringField ::
                 Data.ProtoLens.FieldTypeDescriptor Data.Text.Text)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional
                 (Data.ProtoLens.Field.field @"resourceName")) ::
              Data.ProtoLens.FieldDescriptor ReadRequest
        readOffset__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "read_offset"
              (Data.ProtoLens.ScalarField Data.ProtoLens.Int64Field ::
                 Data.ProtoLens.FieldTypeDescriptor Data.Int.Int64)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional
                 (Data.ProtoLens.Field.field @"readOffset")) ::
              Data.ProtoLens.FieldDescriptor ReadRequest
        readLimit__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "read_limit"
              (Data.ProtoLens.ScalarField Data.ProtoLens.Int64Field ::
                 Data.ProtoLens.FieldTypeDescriptor Data.Int.Int64)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional
                 (Data.ProtoLens.Field.field @"readLimit")) ::
              Data.ProtoLens.FieldDescriptor ReadRequest
      in
        Data.Map.fromList
          [(Data.ProtoLens.Tag 1, resourceName__field_descriptor),
           (Data.ProtoLens.Tag 2, readOffset__field_descriptor),
           (Data.ProtoLens.Tag 3, readLimit__field_descriptor)]
  unknownFields
    = Lens.Family2.Unchecked.lens
        _ReadRequest'_unknownFields
        (\ x__ y__ -> x__ {_ReadRequest'_unknownFields = y__})
  defMessage
    = ReadRequest'_constructor
        {_ReadRequest'resourceName = Data.ProtoLens.fieldDefault,
         _ReadRequest'readOffset = Data.ProtoLens.fieldDefault,
         _ReadRequest'readLimit = Data.ProtoLens.fieldDefault,
         _ReadRequest'_unknownFields = []}
  parseMessage
    = let
        loop ::
          ReadRequest -> Data.ProtoLens.Encoding.Bytes.Parser ReadRequest
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
                                       "resource_name"
                                loop
                                  (Lens.Family2.set
                                     (Data.ProtoLens.Field.field @"resourceName") y x)
                        16
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (Prelude.fmap
                                          Prelude.fromIntegral
                                          Data.ProtoLens.Encoding.Bytes.getVarInt)
                                       "read_offset"
                                loop
                                  (Lens.Family2.set (Data.ProtoLens.Field.field @"readOffset") y x)
                        24
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (Prelude.fmap
                                          Prelude.fromIntegral
                                          Data.ProtoLens.Encoding.Bytes.getVarInt)
                                       "read_limit"
                                loop
                                  (Lens.Family2.set (Data.ProtoLens.Field.field @"readLimit") y x)
                        wire
                          -> do !y <- Data.ProtoLens.Encoding.Wire.parseTaggedValueFromWire
                                        wire
                                loop
                                  (Lens.Family2.over
                                     Data.ProtoLens.unknownFields (\ !t -> (:) y t) x)
      in
        (Data.ProtoLens.Encoding.Bytes.<?>)
          (do loop Data.ProtoLens.defMessage) "ReadRequest"
  buildMessage
    = \ _x
        -> (Data.Monoid.<>)
             (let
                _v
                  = Lens.Family2.view (Data.ProtoLens.Field.field @"resourceName") _x
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
                   _v
                     = Lens.Family2.view (Data.ProtoLens.Field.field @"readOffset") _x
                 in
                   if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                       Data.Monoid.mempty
                   else
                       (Data.Monoid.<>)
                         (Data.ProtoLens.Encoding.Bytes.putVarInt 16)
                         ((Prelude..)
                            Data.ProtoLens.Encoding.Bytes.putVarInt Prelude.fromIntegral _v))
                ((Data.Monoid.<>)
                   (let
                      _v = Lens.Family2.view (Data.ProtoLens.Field.field @"readLimit") _x
                    in
                      if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                          Data.Monoid.mempty
                      else
                          (Data.Monoid.<>)
                            (Data.ProtoLens.Encoding.Bytes.putVarInt 24)
                            ((Prelude..)
                               Data.ProtoLens.Encoding.Bytes.putVarInt Prelude.fromIntegral _v))
                   (Data.ProtoLens.Encoding.Wire.buildFieldSet
                      (Lens.Family2.view Data.ProtoLens.unknownFields _x))))
instance Control.DeepSeq.NFData ReadRequest where
  rnf
    = \ x__
        -> Control.DeepSeq.deepseq
             (_ReadRequest'_unknownFields x__)
             (Control.DeepSeq.deepseq
                (_ReadRequest'resourceName x__)
                (Control.DeepSeq.deepseq
                   (_ReadRequest'readOffset x__)
                   (Control.DeepSeq.deepseq (_ReadRequest'readLimit x__) ())))
{- | Fields :
     
         * 'Proto.Bytestream_Fields.data'' @:: Lens' ReadResponse Data.ByteString.ByteString@ -}
data ReadResponse
  = ReadResponse'_constructor {_ReadResponse'data' :: !Data.ByteString.ByteString,
                               _ReadResponse'_unknownFields :: !Data.ProtoLens.FieldSet}
  deriving stock (Prelude.Eq, Prelude.Ord)
instance Prelude.Show ReadResponse where
  showsPrec _ __x __s
    = Prelude.showChar
        '{'
        (Prelude.showString
           (Data.ProtoLens.showMessageShort __x) (Prelude.showChar '}' __s))
instance Data.ProtoLens.Field.HasField ReadResponse "data'" Data.ByteString.ByteString where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _ReadResponse'data' (\ x__ y__ -> x__ {_ReadResponse'data' = y__}))
        Prelude.id
instance Data.ProtoLens.Message ReadResponse where
  messageName _ = Data.Text.pack "google.bytestream.ReadResponse"
  packedMessageDescriptor _
    = "\n\
      \\fReadResponse\DC2\DC2\n\
      \\EOTdata\CAN\n\
      \ \SOH(\fR\EOTdata"
  packedFileDescriptor _ = packedFileDescriptor
  fieldsByTag
    = let
        data'__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "data"
              (Data.ProtoLens.ScalarField Data.ProtoLens.BytesField ::
                 Data.ProtoLens.FieldTypeDescriptor Data.ByteString.ByteString)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional (Data.ProtoLens.Field.field @"data'")) ::
              Data.ProtoLens.FieldDescriptor ReadResponse
      in
        Data.Map.fromList
          [(Data.ProtoLens.Tag 10, data'__field_descriptor)]
  unknownFields
    = Lens.Family2.Unchecked.lens
        _ReadResponse'_unknownFields
        (\ x__ y__ -> x__ {_ReadResponse'_unknownFields = y__})
  defMessage
    = ReadResponse'_constructor
        {_ReadResponse'data' = Data.ProtoLens.fieldDefault,
         _ReadResponse'_unknownFields = []}
  parseMessage
    = let
        loop ::
          ReadResponse -> Data.ProtoLens.Encoding.Bytes.Parser ReadResponse
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
                        82
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (do len <- Data.ProtoLens.Encoding.Bytes.getVarInt
                                           Data.ProtoLens.Encoding.Bytes.getBytes
                                             (Prelude.fromIntegral len))
                                       "data"
                                loop (Lens.Family2.set (Data.ProtoLens.Field.field @"data'") y x)
                        wire
                          -> do !y <- Data.ProtoLens.Encoding.Wire.parseTaggedValueFromWire
                                        wire
                                loop
                                  (Lens.Family2.over
                                     Data.ProtoLens.unknownFields (\ !t -> (:) y t) x)
      in
        (Data.ProtoLens.Encoding.Bytes.<?>)
          (do loop Data.ProtoLens.defMessage) "ReadResponse"
  buildMessage
    = \ _x
        -> (Data.Monoid.<>)
             (let
                _v = Lens.Family2.view (Data.ProtoLens.Field.field @"data'") _x
              in
                if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                    Data.Monoid.mempty
                else
                    (Data.Monoid.<>)
                      (Data.ProtoLens.Encoding.Bytes.putVarInt 82)
                      ((\ bs
                          -> (Data.Monoid.<>)
                               (Data.ProtoLens.Encoding.Bytes.putVarInt
                                  (Prelude.fromIntegral (Data.ByteString.length bs)))
                               (Data.ProtoLens.Encoding.Bytes.putBytes bs))
                         _v))
             (Data.ProtoLens.Encoding.Wire.buildFieldSet
                (Lens.Family2.view Data.ProtoLens.unknownFields _x))
instance Control.DeepSeq.NFData ReadResponse where
  rnf
    = \ x__
        -> Control.DeepSeq.deepseq
             (_ReadResponse'_unknownFields x__)
             (Control.DeepSeq.deepseq (_ReadResponse'data' x__) ())
{- | Fields :
     
         * 'Proto.Bytestream_Fields.resourceName' @:: Lens' WriteRequest Data.Text.Text@
         * 'Proto.Bytestream_Fields.writeOffset' @:: Lens' WriteRequest Data.Int.Int64@
         * 'Proto.Bytestream_Fields.finishWrite' @:: Lens' WriteRequest Prelude.Bool@
         * 'Proto.Bytestream_Fields.data'' @:: Lens' WriteRequest Data.ByteString.ByteString@ -}
data WriteRequest
  = WriteRequest'_constructor {_WriteRequest'resourceName :: !Data.Text.Text,
                               _WriteRequest'writeOffset :: !Data.Int.Int64,
                               _WriteRequest'finishWrite :: !Prelude.Bool,
                               _WriteRequest'data' :: !Data.ByteString.ByteString,
                               _WriteRequest'_unknownFields :: !Data.ProtoLens.FieldSet}
  deriving stock (Prelude.Eq, Prelude.Ord)
instance Prelude.Show WriteRequest where
  showsPrec _ __x __s
    = Prelude.showChar
        '{'
        (Prelude.showString
           (Data.ProtoLens.showMessageShort __x) (Prelude.showChar '}' __s))
instance Data.ProtoLens.Field.HasField WriteRequest "resourceName" Data.Text.Text where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _WriteRequest'resourceName
           (\ x__ y__ -> x__ {_WriteRequest'resourceName = y__}))
        Prelude.id
instance Data.ProtoLens.Field.HasField WriteRequest "writeOffset" Data.Int.Int64 where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _WriteRequest'writeOffset
           (\ x__ y__ -> x__ {_WriteRequest'writeOffset = y__}))
        Prelude.id
instance Data.ProtoLens.Field.HasField WriteRequest "finishWrite" Prelude.Bool where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _WriteRequest'finishWrite
           (\ x__ y__ -> x__ {_WriteRequest'finishWrite = y__}))
        Prelude.id
instance Data.ProtoLens.Field.HasField WriteRequest "data'" Data.ByteString.ByteString where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _WriteRequest'data' (\ x__ y__ -> x__ {_WriteRequest'data' = y__}))
        Prelude.id
instance Data.ProtoLens.Message WriteRequest where
  messageName _ = Data.Text.pack "google.bytestream.WriteRequest"
  packedMessageDescriptor _
    = "\n\
      \\fWriteRequest\DC2#\n\
      \\rresource_name\CAN\SOH \SOH(\tR\fresourceName\DC2!\n\
      \\fwrite_offset\CAN\STX \SOH(\ETXR\vwriteOffset\DC2!\n\
      \\ffinish_write\CAN\ETX \SOH(\bR\vfinishWrite\DC2\DC2\n\
      \\EOTdata\CAN\n\
      \ \SOH(\fR\EOTdata"
  packedFileDescriptor _ = packedFileDescriptor
  fieldsByTag
    = let
        resourceName__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "resource_name"
              (Data.ProtoLens.ScalarField Data.ProtoLens.StringField ::
                 Data.ProtoLens.FieldTypeDescriptor Data.Text.Text)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional
                 (Data.ProtoLens.Field.field @"resourceName")) ::
              Data.ProtoLens.FieldDescriptor WriteRequest
        writeOffset__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "write_offset"
              (Data.ProtoLens.ScalarField Data.ProtoLens.Int64Field ::
                 Data.ProtoLens.FieldTypeDescriptor Data.Int.Int64)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional
                 (Data.ProtoLens.Field.field @"writeOffset")) ::
              Data.ProtoLens.FieldDescriptor WriteRequest
        finishWrite__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "finish_write"
              (Data.ProtoLens.ScalarField Data.ProtoLens.BoolField ::
                 Data.ProtoLens.FieldTypeDescriptor Prelude.Bool)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional
                 (Data.ProtoLens.Field.field @"finishWrite")) ::
              Data.ProtoLens.FieldDescriptor WriteRequest
        data'__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "data"
              (Data.ProtoLens.ScalarField Data.ProtoLens.BytesField ::
                 Data.ProtoLens.FieldTypeDescriptor Data.ByteString.ByteString)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional (Data.ProtoLens.Field.field @"data'")) ::
              Data.ProtoLens.FieldDescriptor WriteRequest
      in
        Data.Map.fromList
          [(Data.ProtoLens.Tag 1, resourceName__field_descriptor),
           (Data.ProtoLens.Tag 2, writeOffset__field_descriptor),
           (Data.ProtoLens.Tag 3, finishWrite__field_descriptor),
           (Data.ProtoLens.Tag 10, data'__field_descriptor)]
  unknownFields
    = Lens.Family2.Unchecked.lens
        _WriteRequest'_unknownFields
        (\ x__ y__ -> x__ {_WriteRequest'_unknownFields = y__})
  defMessage
    = WriteRequest'_constructor
        {_WriteRequest'resourceName = Data.ProtoLens.fieldDefault,
         _WriteRequest'writeOffset = Data.ProtoLens.fieldDefault,
         _WriteRequest'finishWrite = Data.ProtoLens.fieldDefault,
         _WriteRequest'data' = Data.ProtoLens.fieldDefault,
         _WriteRequest'_unknownFields = []}
  parseMessage
    = let
        loop ::
          WriteRequest -> Data.ProtoLens.Encoding.Bytes.Parser WriteRequest
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
                                       "resource_name"
                                loop
                                  (Lens.Family2.set
                                     (Data.ProtoLens.Field.field @"resourceName") y x)
                        16
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (Prelude.fmap
                                          Prelude.fromIntegral
                                          Data.ProtoLens.Encoding.Bytes.getVarInt)
                                       "write_offset"
                                loop
                                  (Lens.Family2.set (Data.ProtoLens.Field.field @"writeOffset") y x)
                        24
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (Prelude.fmap
                                          ((Prelude./=) 0) Data.ProtoLens.Encoding.Bytes.getVarInt)
                                       "finish_write"
                                loop
                                  (Lens.Family2.set (Data.ProtoLens.Field.field @"finishWrite") y x)
                        82
                          -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (do len <- Data.ProtoLens.Encoding.Bytes.getVarInt
                                           Data.ProtoLens.Encoding.Bytes.getBytes
                                             (Prelude.fromIntegral len))
                                       "data"
                                loop (Lens.Family2.set (Data.ProtoLens.Field.field @"data'") y x)
                        wire
                          -> do !y <- Data.ProtoLens.Encoding.Wire.parseTaggedValueFromWire
                                        wire
                                loop
                                  (Lens.Family2.over
                                     Data.ProtoLens.unknownFields (\ !t -> (:) y t) x)
      in
        (Data.ProtoLens.Encoding.Bytes.<?>)
          (do loop Data.ProtoLens.defMessage) "WriteRequest"
  buildMessage
    = \ _x
        -> (Data.Monoid.<>)
             (let
                _v
                  = Lens.Family2.view (Data.ProtoLens.Field.field @"resourceName") _x
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
                   _v
                     = Lens.Family2.view (Data.ProtoLens.Field.field @"writeOffset") _x
                 in
                   if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                       Data.Monoid.mempty
                   else
                       (Data.Monoid.<>)
                         (Data.ProtoLens.Encoding.Bytes.putVarInt 16)
                         ((Prelude..)
                            Data.ProtoLens.Encoding.Bytes.putVarInt Prelude.fromIntegral _v))
                ((Data.Monoid.<>)
                   (let
                      _v
                        = Lens.Family2.view (Data.ProtoLens.Field.field @"finishWrite") _x
                    in
                      if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                          Data.Monoid.mempty
                      else
                          (Data.Monoid.<>)
                            (Data.ProtoLens.Encoding.Bytes.putVarInt 24)
                            ((Prelude..)
                               Data.ProtoLens.Encoding.Bytes.putVarInt (\ b -> if b then 1 else 0)
                               _v))
                   ((Data.Monoid.<>)
                      (let
                         _v = Lens.Family2.view (Data.ProtoLens.Field.field @"data'") _x
                       in
                         if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                             Data.Monoid.mempty
                         else
                             (Data.Monoid.<>)
                               (Data.ProtoLens.Encoding.Bytes.putVarInt 82)
                               ((\ bs
                                   -> (Data.Monoid.<>)
                                        (Data.ProtoLens.Encoding.Bytes.putVarInt
                                           (Prelude.fromIntegral (Data.ByteString.length bs)))
                                        (Data.ProtoLens.Encoding.Bytes.putBytes bs))
                                  _v))
                      (Data.ProtoLens.Encoding.Wire.buildFieldSet
                         (Lens.Family2.view Data.ProtoLens.unknownFields _x)))))
instance Control.DeepSeq.NFData WriteRequest where
  rnf
    = \ x__
        -> Control.DeepSeq.deepseq
             (_WriteRequest'_unknownFields x__)
             (Control.DeepSeq.deepseq
                (_WriteRequest'resourceName x__)
                (Control.DeepSeq.deepseq
                   (_WriteRequest'writeOffset x__)
                   (Control.DeepSeq.deepseq
                      (_WriteRequest'finishWrite x__)
                      (Control.DeepSeq.deepseq (_WriteRequest'data' x__) ()))))
{- | Fields :
     
         * 'Proto.Bytestream_Fields.committedSize' @:: Lens' WriteResponse Data.Int.Int64@ -}
data WriteResponse
  = WriteResponse'_constructor {_WriteResponse'committedSize :: !Data.Int.Int64,
                                _WriteResponse'_unknownFields :: !Data.ProtoLens.FieldSet}
  deriving stock (Prelude.Eq, Prelude.Ord)
instance Prelude.Show WriteResponse where
  showsPrec _ __x __s
    = Prelude.showChar
        '{'
        (Prelude.showString
           (Data.ProtoLens.showMessageShort __x) (Prelude.showChar '}' __s))
instance Data.ProtoLens.Field.HasField WriteResponse "committedSize" Data.Int.Int64 where
  fieldOf _
    = (Prelude..)
        (Lens.Family2.Unchecked.lens
           _WriteResponse'committedSize
           (\ x__ y__ -> x__ {_WriteResponse'committedSize = y__}))
        Prelude.id
instance Data.ProtoLens.Message WriteResponse where
  messageName _ = Data.Text.pack "google.bytestream.WriteResponse"
  packedMessageDescriptor _
    = "\n\
      \\rWriteResponse\DC2%\n\
      \\SOcommitted_size\CAN\SOH \SOH(\ETXR\rcommittedSize"
  packedFileDescriptor _ = packedFileDescriptor
  fieldsByTag
    = let
        committedSize__field_descriptor
          = Data.ProtoLens.FieldDescriptor
              "committed_size"
              (Data.ProtoLens.ScalarField Data.ProtoLens.Int64Field ::
                 Data.ProtoLens.FieldTypeDescriptor Data.Int.Int64)
              (Data.ProtoLens.PlainField
                 Data.ProtoLens.Optional
                 (Data.ProtoLens.Field.field @"committedSize")) ::
              Data.ProtoLens.FieldDescriptor WriteResponse
      in
        Data.Map.fromList
          [(Data.ProtoLens.Tag 1, committedSize__field_descriptor)]
  unknownFields
    = Lens.Family2.Unchecked.lens
        _WriteResponse'_unknownFields
        (\ x__ y__ -> x__ {_WriteResponse'_unknownFields = y__})
  defMessage
    = WriteResponse'_constructor
        {_WriteResponse'committedSize = Data.ProtoLens.fieldDefault,
         _WriteResponse'_unknownFields = []}
  parseMessage
    = let
        loop ::
          WriteResponse -> Data.ProtoLens.Encoding.Bytes.Parser WriteResponse
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
                        8 -> do y <- (Data.ProtoLens.Encoding.Bytes.<?>)
                                       (Prelude.fmap
                                          Prelude.fromIntegral
                                          Data.ProtoLens.Encoding.Bytes.getVarInt)
                                       "committed_size"
                                loop
                                  (Lens.Family2.set
                                     (Data.ProtoLens.Field.field @"committedSize") y x)
                        wire
                          -> do !y <- Data.ProtoLens.Encoding.Wire.parseTaggedValueFromWire
                                        wire
                                loop
                                  (Lens.Family2.over
                                     Data.ProtoLens.unknownFields (\ !t -> (:) y t) x)
      in
        (Data.ProtoLens.Encoding.Bytes.<?>)
          (do loop Data.ProtoLens.defMessage) "WriteResponse"
  buildMessage
    = \ _x
        -> (Data.Monoid.<>)
             (let
                _v
                  = Lens.Family2.view
                      (Data.ProtoLens.Field.field @"committedSize") _x
              in
                if (Prelude.==) _v Data.ProtoLens.fieldDefault then
                    Data.Monoid.mempty
                else
                    (Data.Monoid.<>)
                      (Data.ProtoLens.Encoding.Bytes.putVarInt 8)
                      ((Prelude..)
                         Data.ProtoLens.Encoding.Bytes.putVarInt Prelude.fromIntegral _v))
             (Data.ProtoLens.Encoding.Wire.buildFieldSet
                (Lens.Family2.view Data.ProtoLens.unknownFields _x))
instance Control.DeepSeq.NFData WriteResponse where
  rnf
    = \ x__
        -> Control.DeepSeq.deepseq
             (_WriteResponse'_unknownFields x__)
             (Control.DeepSeq.deepseq (_WriteResponse'committedSize x__) ())
data ByteStream = ByteStream {}
instance Data.ProtoLens.Service.Types.Service ByteStream where
  type ServiceName ByteStream = "ByteStream"
  type ServicePackage ByteStream = "google.bytestream"
  type ServiceMethods ByteStream = '["read", "write"]
  packedServiceDescriptor _
    = "\n\
      \\n\
      \ByteStream\DC2I\n\
      \\EOTRead\DC2\RS.google.bytestream.ReadRequest\SUB\US.google.bytestream.ReadResponse0\SOH\DC2L\n\
      \\ENQWrite\DC2\US.google.bytestream.WriteRequest\SUB .google.bytestream.WriteResponse(\SOH"
instance Data.ProtoLens.Service.Types.HasMethodImpl ByteStream "read" where
  type MethodName ByteStream "read" = "Read"
  type MethodInput ByteStream "read" = ReadRequest
  type MethodOutput ByteStream "read" = ReadResponse
  type MethodStreamingType ByteStream "read" = 'Data.ProtoLens.Service.Types.ServerStreaming
instance Data.ProtoLens.Service.Types.HasMethodImpl ByteStream "write" where
  type MethodName ByteStream "write" = "Write"
  type MethodInput ByteStream "write" = WriteRequest
  type MethodOutput ByteStream "write" = WriteResponse
  type MethodStreamingType ByteStream "write" = 'Data.ProtoLens.Service.Types.ClientStreaming
packedFileDescriptor :: Data.ByteString.ByteString
packedFileDescriptor
  = "\n\
    \\DLEbytestream.proto\DC2\DC1google.bytestream\"r\n\
    \\vReadRequest\DC2#\n\
    \\rresource_name\CAN\SOH \SOH(\tR\fresourceName\DC2\US\n\
    \\vread_offset\CAN\STX \SOH(\ETXR\n\
    \readOffset\DC2\GS\n\
    \\n\
    \read_limit\CAN\ETX \SOH(\ETXR\treadLimit\"\"\n\
    \\fReadResponse\DC2\DC2\n\
    \\EOTdata\CAN\n\
    \ \SOH(\fR\EOTdata\"\141\SOH\n\
    \\fWriteRequest\DC2#\n\
    \\rresource_name\CAN\SOH \SOH(\tR\fresourceName\DC2!\n\
    \\fwrite_offset\CAN\STX \SOH(\ETXR\vwriteOffset\DC2!\n\
    \\ffinish_write\CAN\ETX \SOH(\bR\vfinishWrite\DC2\DC2\n\
    \\EOTdata\CAN\n\
    \ \SOH(\fR\EOTdata\"6\n\
    \\rWriteResponse\DC2%\n\
    \\SOcommitted_size\CAN\SOH \SOH(\ETXR\rcommittedSize2\165\SOH\n\
    \\n\
    \ByteStream\DC2I\n\
    \\EOTRead\DC2\RS.google.bytestream.ReadRequest\SUB\US.google.bytestream.ReadResponse0\SOH\DC2L\n\
    \\ENQWrite\DC2\US.google.bytestream.WriteRequest\SUB .google.bytestream.WriteResponse(\SOHB\ETB\n\
    \\NAKcom.google.bytestreamJ\182\v\n\
    \\ACK\DC2\EOT\a\NUL%\SOH\n\
    \\155\ENQ\n\
    \\SOH\f\DC2\ETX\a\NUL\DC22\144\ENQ \226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\n\
    \                                              // nix-serve-cas // bytestream\n\
    \ \226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\226\148\129\n\
    \\n\
    \ Google ByteStream API - for large blob upload/download\n\
    \ Source: https://github.com/googleapis/googleapis\n\
    \\n\
    \\b\n\
    \\SOH\STX\DC2\ETX\t\NUL\SUB\n\
    \\b\n\
    \\SOH\b\DC2\ETX\v\NUL.\n\
    \\t\n\
    \\STX\b\SOH\DC2\ETX\v\NUL.\n\
    \\n\
    \\n\
    \\STX\EOT\NUL\DC2\EOT\r\NUL\DC1\SOH\n\
    \\n\
    \\n\
    \\ETX\EOT\NUL\SOH\DC2\ETX\r\b\DC3\n\
    \\v\n\
    \\EOT\EOT\NUL\STX\NUL\DC2\ETX\SO\STX\ESC\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\NUL\ENQ\DC2\ETX\SO\STX\b\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\NUL\SOH\DC2\ETX\SO\t\SYN\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\NUL\ETX\DC2\ETX\SO\EM\SUB\n\
    \\v\n\
    \\EOT\EOT\NUL\STX\SOH\DC2\ETX\SI\STX\CAN\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\SOH\ENQ\DC2\ETX\SI\STX\a\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\SOH\SOH\DC2\ETX\SI\b\DC3\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\SOH\ETX\DC2\ETX\SI\SYN\ETB\n\
    \\v\n\
    \\EOT\EOT\NUL\STX\STX\DC2\ETX\DLE\STX\ETB\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\STX\ENQ\DC2\ETX\DLE\STX\a\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\STX\SOH\DC2\ETX\DLE\b\DC2\n\
    \\f\n\
    \\ENQ\EOT\NUL\STX\STX\ETX\DC2\ETX\DLE\NAK\SYN\n\
    \\n\
    \\n\
    \\STX\EOT\SOH\DC2\EOT\DC3\NUL\NAK\SOH\n\
    \\n\
    \\n\
    \\ETX\EOT\SOH\SOH\DC2\ETX\DC3\b\DC4\n\
    \\v\n\
    \\EOT\EOT\SOH\STX\NUL\DC2\ETX\DC4\STX\DC2\n\
    \\f\n\
    \\ENQ\EOT\SOH\STX\NUL\ENQ\DC2\ETX\DC4\STX\a\n\
    \\f\n\
    \\ENQ\EOT\SOH\STX\NUL\SOH\DC2\ETX\DC4\b\f\n\
    \\f\n\
    \\ENQ\EOT\SOH\STX\NUL\ETX\DC2\ETX\DC4\SI\DC1\n\
    \\n\
    \\n\
    \\STX\EOT\STX\DC2\EOT\ETB\NUL\FS\SOH\n\
    \\n\
    \\n\
    \\ETX\EOT\STX\SOH\DC2\ETX\ETB\b\DC4\n\
    \\v\n\
    \\EOT\EOT\STX\STX\NUL\DC2\ETX\CAN\STX\ESC\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\NUL\ENQ\DC2\ETX\CAN\STX\b\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\NUL\SOH\DC2\ETX\CAN\t\SYN\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\NUL\ETX\DC2\ETX\CAN\EM\SUB\n\
    \\v\n\
    \\EOT\EOT\STX\STX\SOH\DC2\ETX\EM\STX\EM\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\SOH\ENQ\DC2\ETX\EM\STX\a\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\SOH\SOH\DC2\ETX\EM\b\DC4\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\SOH\ETX\DC2\ETX\EM\ETB\CAN\n\
    \\v\n\
    \\EOT\EOT\STX\STX\STX\DC2\ETX\SUB\STX\CAN\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\STX\ENQ\DC2\ETX\SUB\STX\ACK\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\STX\SOH\DC2\ETX\SUB\a\DC3\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\STX\ETX\DC2\ETX\SUB\SYN\ETB\n\
    \\v\n\
    \\EOT\EOT\STX\STX\ETX\DC2\ETX\ESC\STX\DC2\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\ETX\ENQ\DC2\ETX\ESC\STX\a\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\ETX\SOH\DC2\ETX\ESC\b\f\n\
    \\f\n\
    \\ENQ\EOT\STX\STX\ETX\ETX\DC2\ETX\ESC\SI\DC1\n\
    \\n\
    \\n\
    \\STX\EOT\ETX\DC2\EOT\RS\NUL \SOH\n\
    \\n\
    \\n\
    \\ETX\EOT\ETX\SOH\DC2\ETX\RS\b\NAK\n\
    \\v\n\
    \\EOT\EOT\ETX\STX\NUL\DC2\ETX\US\STX\ESC\n\
    \\f\n\
    \\ENQ\EOT\ETX\STX\NUL\ENQ\DC2\ETX\US\STX\a\n\
    \\f\n\
    \\ENQ\EOT\ETX\STX\NUL\SOH\DC2\ETX\US\b\SYN\n\
    \\f\n\
    \\ENQ\EOT\ETX\STX\NUL\ETX\DC2\ETX\US\EM\SUB\n\
    \\n\
    \\n\
    \\STX\ACK\NUL\DC2\EOT\"\NUL%\SOH\n\
    \\n\
    \\n\
    \\ETX\ACK\NUL\SOH\DC2\ETX\"\b\DC2\n\
    \\v\n\
    \\EOT\ACK\NUL\STX\NUL\DC2\ETX#\STX6\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\NUL\SOH\DC2\ETX#\ACK\n\
    \\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\NUL\STX\DC2\ETX#\v\SYN\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\NUL\ACK\DC2\ETX#!'\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\NUL\ETX\DC2\ETX#(4\n\
    \\v\n\
    \\EOT\ACK\NUL\STX\SOH\DC2\ETX$\STX9\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\SOH\SOH\DC2\ETX$\ACK\v\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\SOH\ENQ\DC2\ETX$\f\DC2\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\SOH\STX\DC2\ETX$\DC3\US\n\
    \\f\n\
    \\ENQ\ACK\NUL\STX\SOH\ETX\DC2\ETX$*7b\ACKproto3"