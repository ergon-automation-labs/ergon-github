%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      checks: [
        {Credo.Check.Refactor.Nesting, max_nesting: 4},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Design.TagFIXME, false},
        {Credo.Check.Warning.UnusedLoggerMetadata, false}
      ]
    }
  ]
}
