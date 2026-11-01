# Music streaming distribution format for Spotify albums

`spotify-music-streaming.rq` finds albums (instance of album, Q482994) with a Spotify album ID (P2205) and no "distribution format: music streaming" statement (P437 = Q15982450) at any rank. Each result row is a ready QuickStatements v1 command that adds the statement with the reference inferred from (P3452): Spotify (Q689141).

Run it on the Wikidata Query Service, download the results as TSV, drop the header row and the quotes, and paste the lines into QuickStatements. Each line is tab-separated:

```
Q91044673	P437	Q15982450	S3452	Q689141
```

The same approach would work for Apple Music album IDs (P2281) and Deezer album IDs (P2723). Their constraints also ask for distribution format: music streaming.
