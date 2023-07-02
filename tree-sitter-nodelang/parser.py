#! /usr/bin/env python3

"""
"""

__author__ = 'Michael Belousov'

import tree_sitter
import unittest

binding_file = 'bindings/python/nodelang.so'

tree_sitter.Language.build_library(binding_file, ['.'])
NODELANG_LANG = tree_sitter.Language(binding_file, 'nodelang')

nodelang_parser = tree_sitter.Parser()
nodelang_parser.set_language(NODELANG_LANG)

