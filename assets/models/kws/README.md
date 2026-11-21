# Wake word model ("SeeRuta")

Keyword-spotting model used by `lib/services/wake_word_service.dart` with
sherpa-onnx (on-device, no network).

- Source: https://github.com/k2-fsa/sherpa-onnx/releases/tag/kws-models
- Archive: `sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2`
- Model: streaming zipformer transducer, 3M parameters, Chinese + English,
  `chunk-16` export (320 ms decision latency), int8 encoder/joiner.
- License: Apache 2.0.

Only the files the app loads are copied here (5.5 MB): the int8 encoder and
joiner, the float decoder, `tokens.txt`, and `keywords.txt`. `en.phone`
(3.3 MB) is only needed by the `text2token` tool to turn English words into
phonemes; the app ships the generated keyword line instead.

## Keywords

`keywords.txt` holds one keyword per line as phoneme tokens, with `@` and the
display name at the end:

```
S IY1 R UW1 T AH0 @SeeRuta      # see-roo-ta
```

A line may end with `:score` (keyword boost, default 1.0) and `#threshold`
(acoustic probability, default 0.25), e.g.
`S IY1 R UW1 T AH0 @SeeRuta :2.0 #0.2`. Raise the score or lower the
threshold if the wake word is missed; lower the score or raise the threshold
if the assistant wakes on ordinary speech.

This model was chosen over the English-only GigaSpeech KWS model because its
English keywords are phonemes, which handles an invented word precisely; the
BPE-based English model did not detect "SeeRuta" in testing with natural
synthesised speech, while this one detects it and ignores unrelated speech.
