import os
import lit.formats

config.name = "CustomDSE"
config.test_format = lit.formats.ShTest(True)
config.suffixes = [".ll"]
config.test_source_root = os.path.dirname(__file__)
config.test_exec_root = os.path.dirname(__file__)
