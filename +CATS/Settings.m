classdef Settings < handle
    % Settings
    %
    % Per-user settings saved as JSON in %APPDATA%\CATS\settings.json, so
    % they survive restarts of the compiled app:
    %
    %   DataRoot        where sweeps, metadata, logs and reports go
    %   ProfilesFolder  where part profiles (*.json) are read from
    %   Theme           "light" | "dark"
    %   LastOperator, LastWorkOrder, LastProfile
    %   VNAResource     last VNA resource used (tried first on launch)
    %   ShowSim         list the simulated VNA (testing)
    %
    % Usage:
    %
    %   s = CATS.Settings.load();
    %   s.Theme = "dark";
    %   s.save();
    %

    properties

        DataRoot string = ""

        ProfilesFolder string = ""

        Theme string = "light"

        LastOperator string = ""

        LastWorkOrder string = ""

        LastProfile string = ""

        VNAResource string = ""

        ShowSim logical = false

        %
        % Last override statement used, per profile + criterion
        % (pre-fills the next batch's statement)
        %
        OverrideStatements struct = struct()

    end

    properties (SetAccess = private)

        File string = ""

    end

    methods (Static)

        function s = load(file)
            % Load settings, filling defaults for anything missing.

            arguments
                file {mustBeTextScalar} = CATS.Settings.defaultFile()
            end

            s = CATS.Settings();

            s.File = string(file);

            if isfile(file)

                try

                    saved = jsondecode(fileread(file));

                    for name = string(fieldnames(saved)).'

                        if isprop(s, name) && name ~= "File"
                            s.(name) = saved.(name);
                        end

                    end

                catch ME

                    warning('CATS:Settings', ...
                        'Could not read settings (%s); using defaults.', ME.message);

                end

            end

            s.applyDefaults();

        end

        function key = overrideKey(profileName, criterionId)

            key = matlab.lang.makeValidName("P_" + profileName + "_" + criterionId);

        end

        function file = defaultFile()

            file = string(fullfile(CATS.Settings.userFolder(), "settings.json"));

        end

        function folder = userFolder()

            base = getenv('APPDATA');

            if isempty(base)
                base = tempdir;
            end

            folder = fullfile(base, 'CATS');

        end

        function folder = sharedFolder()
            % Default home for data and editable profiles:
            % C:\Users\Public\Documents\CATS

            base = getenv('PUBLIC');

            if isempty(base)
                base = CATS.Settings.userFolder();
            else
                base = fullfile(base, 'Documents');
            end

            folder = string(fullfile(base, 'CATS'));

        end

    end

    methods

        function text = overrideStatement(obj, profileName, criterionId)
            % Last statement used for this profile + criterion ("" if none).

            key = CATS.Settings.overrideKey(profileName, criterionId);

            text = "";

            if isfield(obj.OverrideStatements, key)
                text = string(obj.OverrideStatements.(key));
            end

        end

        function setOverrideStatement(obj, profileName, criterionId, text)

            key = CATS.Settings.overrideKey(profileName, criterionId);

            obj.OverrideStatements.(key) = char(text);

        end

        function save(obj)

            folder = fileparts(obj.File);

            if ~isfolder(folder)
                mkdir(folder);
            end

            data = struct();

            for name = ["DataRoot","ProfilesFolder","Theme","LastOperator", ...
                    "LastWorkOrder","LastProfile","VNAResource","ShowSim", ...
                    "OverrideStatements"]
                data.(name) = obj.(name);
            end

            fid = fopen(obj.File, 'w');

            fprintf(fid, '%s', jsonencode(data, PrettyPrint=true));

            fclose(fid);

        end

    end

    methods (Access = private)

        function applyDefaults(obj)

            if strlength(obj.DataRoot) == 0
                obj.DataRoot = fullfile(CATS.Settings.sharedFolder(), "Data");
            end

            if strlength(obj.ProfilesFolder) == 0
                obj.ProfilesFolder = fullfile(CATS.Settings.sharedFolder(), "Profiles");
            end

            if ~ismember(obj.Theme, ["light","dark"])
                obj.Theme = "light";
            end

            if strlength(obj.LastOperator) == 0
                obj.LastOperator = string(getenv('USERNAME'));
            end

        end

    end

end
