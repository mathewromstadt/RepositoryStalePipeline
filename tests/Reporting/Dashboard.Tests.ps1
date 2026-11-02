BeforeAll {
    $root = (Resolve-Path "$PSScriptRoot/../..").Path
}
Describe 'Repository table dashboard contracts' {
    It 'keeps Classic and V1 resource dashboards equivalent' {
        $classic = Get-Content "$root/dashboards/grafana/governance.json" -Raw | ConvertFrom-Json -AsHashtable
        $resource = Get-Content "$root/dashboards/grafana/governance.resource.json" -Raw | ConvertFrom-Json -AsHashtable
        ($classic | ConvertTo-Json -Depth 100 -Compress) | Should -Be ($resource.spec | ConvertTo-Json -Depth 100 -Compress)
        $table = @($classic.panels | Where-Object type -eq 'table')[0]
        $table.targets[0].expr | Should -Match 'RepositoryStatus'
        $table.targets[0].maxLines | Should -Be 5000
        $group = @($table.transformations | Where-Object id -eq 'groupBy')[0]
        foreach ($field in @('organization', 'project', 'repository')) {
            $group.options.fields[$field].operation | Should -Be 'groupby'
        }
        $group.options.fields.status.aggregations[0] | Should -Be 'last'
    }
}