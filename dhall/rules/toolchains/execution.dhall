--| Execution platforms for Buck2 remote execution (LRE)
--|
--| By default, the prelude's execution_platform has remote_enabled=False.
--| These platforms enable remote execution for NativeLink.

let R = ../Rule.dhall
let S = ../to-starlark.dhall

let lreExecutionPlatform =
      { impl = 
          (R.ruleImpl "lre_execution_platform" ''
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    cfg = ConfigurationInfo(constraints = constraints, values = {})

    name = ctx.label.raw_target()

    # Build executor config based on whether remote is enabled
    if ctx.attrs.remote_enabled:
        executor_config = CommandExecutorConfig(
            local_enabled = ctx.attrs.local_enabled,
            remote_enabled = True,
            use_windows_path_separators = False,
            remote_execution_properties = {
                "OSFamily": "linux",
                "container-image": "nix-worker",
            },
            remote_execution_use_case = "buck2-default",
            remote_output_paths = "output_paths",
        )
    else:
        executor_config = CommandExecutorConfig(
            local_enabled = ctx.attrs.local_enabled,
            remote_enabled = False,
            use_windows_path_separators = False,
        )

    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = executor_config,
    )

    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(platforms = [platform]),
    ]
'')
            with doc = "Execution platform with remote execution enabled."
      , attrs = 
          [ (R.attr "cpu_configuration" (R.AttrType.Dep {=}))
              with doc = "CPU configuration provider"
          , (R.attr "os_configuration" (R.AttrType.Dep {=}))
              with doc = "OS configuration provider"
          , R.boolAttr "local_enabled" True
          , R.boolAttr "remote_enabled" True
          ]
      }

let hostCpuConfiguration =
      R.helper "_host_cpu_configuration" ([] : List Text) ''
    arch = host_info().arch
    if arch.is_aarch64:
        return "prelude//cpu:arm64"
    elif arch.is_arm:
        return "prelude//cpu:arm32"
    elif arch.is_i386:
        return "prelude//cpu:x86_32"
    else:
        return "prelude//cpu:x86_64"
''

let hostOsConfiguration =
      R.helper "_host_os_configuration" ([] : List Text) ''
    os = host_info().os
    if os.is_macos:
        return "prelude//os:macos"
    elif os.is_windows:
        return "prelude//os:windows"
    else:
        return "prelude//os:linux"
''

let file =
        R.bzlFile
          with header = ''
# Execution platforms for Buck2 remote execution (LRE).
''
          with helpers = [ hostCpuConfiguration, hostOsConfiguration ]
          with rules = [ lreExecutionPlatform ]

-- Extra starlark to append (host_configuration struct)
let footer = ''
host_configuration = struct(
    cpu = _host_cpu_configuration(),
    os = _host_os_configuration(),
)
''

in  { file, footer, render = S.renderBzlFile file ++ footer }
