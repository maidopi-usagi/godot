def can_build(env, platform):
    return env.get("rive_enabled", False)


def configure(env):
    pass


def get_doc_classes():
    return [
        "RiveViewer",
    ]


def get_doc_path():
    return "doc_classes"


def get_opts(platform):
    from SCons.Variables import BoolVariable
    return [
        BoolVariable("rive_enabled", "Enable the Rive module", False),
    ]
