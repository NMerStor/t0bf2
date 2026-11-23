local isWindows = package.config:sub(1,1) == "\\";
local compilerPath = "./luau-master/luau-compile" .. (isWindows and ".exe" or "");

return {
    ["luaubc"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";
        NameGenerator = "shortrand";
        PrettyPrint = false;
        Seed = 0;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };
            {
                Name = "ControlFlowFlattening";
                Settings = {
                    MinStatements = 4;
                    Probability   = 1.0;
                };
            };
            {
                Name = "LuauBytecode";
                Settings = {
                    CompilerPath = compilerPath;
                    OptLevel = 2;
                    Remap = true;
                    EncryptBytecode = true;
                    B85 = true;
                    PolymorphicVM   = true;
                    VMStyle         = "split";
                    VMRegisterRemap = true;
                    VMConstRemap    = true;
                    VMContainerSchema = "derived";
                };
            };
            { Name = "DummyStep"; Settings = { Intensity = 0.2; }; };
            { Name = "ConstantArray"; Settings = { Rotate = false; }; };
            {
                Name = "EnhancedVmCompression";
                Settings = {
                    Enabled   = true;
                    Algorithm = "zlib";
                    Encode    = "b85";
                    Mode      = "source";
                    MinGain   = 0.05;
                };
            };
        };
    };

    ["customvm-small"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";
        NameGenerator = "shortrand";
        PrettyPrint = false;
        Seed = 0;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };
            { Name = "CustomVM"; Settings = {
                Flatten = true;
                FlattenIntensity = "max";
                MicroOps = true;
            }; };
            { Name = "AntiTamper"; Settings = {}; };
            { Name = "DummyStep"; Settings = { Intensity = 0.8; }; };
            { Name = "ConstantArray"; Settings = { Rotate = false; }; };
        };
    };

    ["customvm"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";
        NameGenerator = "shortrand";
        PrettyPrint = false;
        Seed = 0;
        JunkLevel = 0;
        DispatcherJunk = 0;
        AggressiveOpt = true;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };
            { Name = "SADOX_INLINE"; Settings = {}; };
            { Name = "StringXOR"; Settings = { Probability = 0.9; }; };
            { Name = "OpaquePredicates"; Settings = { Probability = 0.85; }; };
            { Name = "DeadCode"; Settings = { Probability = 0.3; }; };
            { Name = "VariableSplitting"; Settings = { Probability = 0.7; }; };
            { Name = "HelperTable"; Settings = {}; };
            { Name = "SplitStrings"; Settings = {
                Treshold          = 1;
                MinLength         = 2;
                MaxLength         = 5;
                ConcatenationType = "strcat";
            }; };
            {
                Name = "ControlFlowFlattening";
                Settings = {
                    MinStatements = 10;
                    Probability   = 0.6;
                };
            };
            { Name = "CustomVM"; Settings = {
                Flatten          = false;
                FlattenIntensity = "high";
                MicroOps         = true;
                JunkLevel        = 2;
                Compress         = true;
            }; };
            { Name = "EncryptStrings"; Settings = { EncryptNumbers = true; }; };
            { Name = "AntiTamper"; Settings = {}; };
            { Name = "DummyStep"; Settings = { Intensity = 0.4; }; };
            { Name = "ConstantArray"; Settings = {
                Encoding     = "b85";
                Rotate       = true;
                Shuffle      = true;
                StringsOnly  = true;
                Treshold     = 1;
                MaxStringLen = 256;
            }; };
        };
    };

    ["customvm-large"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";
        NameGenerator = "shortrand";
        PrettyPrint = false;
        Seed = 0;
        JunkLevel = 0;
        DispatcherJunk = 1;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };
            { Name = "CustomVM"; Settings = {
                Flatten = true;
                FlattenIntensity = "high";
                MicroOps = true;
                JunkLevel = 0;
            }; };
            { Name = "AntiTamper"; Settings = {}; };
            { Name = "DummyStep"; Settings = { Intensity = 0.3; }; };
        };
    };

    ["ironbrew2"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";
        NameGenerator = "shortrand";
        PrettyPrint = false;
        Seed = 0;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };
            { Name = "IronBrew2VM"; Settings = {
                XorKey = 0;
                Mutate = true;
            }; };
        };
    };

    ["customvm-allstricks"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";
        NameGenerator = "shortrand";
        PrettyPrint = false;
        Seed = 0;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };
            { Name = "SADOX_INLINE"; Settings = {}; };
            { Name = "StringXOR"; Settings = { Probability = 0.9; }; };
            { Name = "OpaquePredicates"; Settings = { Probability = 0.85; }; };
            { Name = "DeadCode"; Settings = { Probability = 0.3; }; };
            { Name = "VariableSplitting"; Settings = { Probability = 0.7; }; };
            { Name = "HelperTable"; Settings = {}; };
            { Name = "SplitStrings"; Settings = {
                Treshold          = 1;
                MinLength         = 2;
                MaxLength         = 4;
                ConcatenationType = "strcat";
            }; };
            {
                Name = "ControlFlowFlattening";
                Settings = {
                    MinStatements = 10;
                    Probability   = 0.75;
                };
            };
            { Name = "CustomVM"; Settings = {
                Flatten          = true;
                FlattenIntensity = "max";
                FlattenMinBlocks = 3;
                FlattenChance    = 1.0;
                MicroOps         = true;
                JunkLevel        = 2;
                Compress         = true;
            }; };
            { Name = "EncryptStrings"; Settings = { EncryptNumbers = true; }; };
            { Name = "AntiTamper"; Settings = {}; };
            { Name = "DummyStep"; Settings = {
                Intensity = 0.6;
            }; };
            { Name = "ConstantArray"; Settings = {
                Encoding     = "b85";
                Rotate       = true;
                Shuffle      = true;
                StringsOnly  = true;
                Treshold     = 1;
                MaxStringLen = 256;
            }; };
            { Name = "ReturnTable"; Settings = {}; };
        };
    };

    ["catph"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";

        NameGenerator = "ib1";
        PrettyPrint = false;
        Seed = 0;

        DispatcherJunk = 3;
        JunkLevel = 2;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };

            { Name = "StringXOR"; Settings = { Probability = 1.0; }; };

            { Name = "CatphEncurl"; Settings = { Probability = 0.95; }; };

            { Name = "SplitStrings"; Settings = {
                Treshold          = 1.0;
                MinLength         = 2;
                MaxLength         = 4;
                ConcatenationType = "strcat";
            }; };

            { Name = "NumbersToExpressions"; Settings = {
                Treshold = 1.0;
                InternalTreshold = 0.12;
            }; };

            { Name = "AntiDumpConstants"; Settings = {
                Probability = 0.85;
                MaxValue    = 8191;
            }; };

            { Name = "OpaquePredicates"; Settings = { Probability = 0.95; }; };

            { Name = "DeadCode"; Settings = { Probability = 0.5; }; };

            { Name = "HelperTable"; Settings = {}; };

            { Name = "ControlFlowFlattening"; Settings = {
                MinStatements = 3;
                Probability   = 0.90;
            }; };

            { Name = "DummyStep"; Settings = { Intensity = 0.85; }; };

            { Name = "DummyStep"; Settings = { Intensity = 0.70; }; };
        };
    };

    ["customvm-test"] = {
        LuaVersion = "LuaU";
        VarNamePrefix = "";
        NameGenerator = "shortrand";
        PrettyPrint = false;
        Seed = 0;
        Steps = {
            { Name = "MacroExpand"; Settings = {}; };
            { Name = "CustomVM"; Settings = {
                Flatten = true;
                FlattenIntensity = "high";
                MicroOps = true;
            }; };
        };
    };
}
