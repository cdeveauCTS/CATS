classdef App < handle
    % App
    %
    % CATS - CTS Acceptance Test System.
    %
    % Room-temperature bench acceptance testing:
    %
    %   1. On launch, find and connect the VNA.
    %   2. Start a batch: part profile, operator, work order, first serial.
    %      The profile's sweep is pushed to the VNA, the operator runs
    %      ECal, and the cal is verified before testing is allowed.
    %   3. Sweep continuously; every criterion is shown live.
    %   4. PASS (only when every criterion passes) or FAIL saves the
    %      sweep + metadata and moves to the next serial number.
    %   5. Finish Batch writes the test report.
    %
    % Tabs: Test | Log | Review | Reports. Light/Dark switch in the header.
    %
    % Usage:
    %
    %   app = CATS.App();
    %
    %   % Testing: own settings file, simulated VNA, scripted dialogs
    %   app = CATS.App(SettingsFile="C:\temp\s.json", IncludeSim=true);
    %

    properties (Constant)

        Version = "0.1.0"

    end

    properties (SetAccess = private)

        Figure

        Settings

        Driver = []

        VNAInfo struct = struct('Model', "", 'Resource', "", 'IDN', "")

        Profiles struct = struct([])

        Batch struct = struct([])

        Serial string = ""

        CalVerified logical = false

        CalInfo struct = struct()

        Sweeping logical = false

        LastSweep = []

        LastResults table = table()

        Records struct = struct([])

        ReviewItems struct = struct([])

    end

    properties

        %
        % Testing hook: answers returned by dialogs, in order, instead
        % of showing them. Each entry is the option text to "click".
        %
        ScriptedAnswers string = strings(0,1)

        %
        % Idle gap after each sweep finishes before the next starts
        % (fixed spacing), so the window and MATLAB stay responsive
        % however long a sweep takes. Not less than 0.3 s.
        %
        SweepGapSec double = 0.5

    end

    properties (Access = private)

        H struct = struct()

        Timer = []

        WideLines = gobjects(0)

        NarrowLines = gobjects(0)

        %
        % Override statement per criterion Id for the current batch,
        % reused part to part
        %
        OverrideStatements struct = struct()

        IncludeSim logical = false

        EditingSerial logical = false

        %
        % Serial to return to after a retest (set when the serial is
        % changed by hand to an already-tested part)
        %
        ResumeSerial string = ""

    end

    %==============================================================
    % CONSTRUCTION
    %==============================================================
    methods

        function obj = App(options)

            arguments
                options.SettingsFile {mustBeTextScalar} = CATS.Settings.defaultFile()
                options.AutoConnect (1,1) logical = true
                options.IncludeSim (1,1) logical = false
            end

            obj.Settings = CATS.Settings.load(options.SettingsFile);

            obj.IncludeSim = options.IncludeSim || obj.Settings.ShowSim;

            obj.buildUI();

            obj.loadProfiles();

            obj.refresh();

            obj.Figure.Visible = "on";

            obj.Figure.WindowState = "maximized";

            drawnow;

            if options.AutoConnect
                obj.connectVNA();
            end

        end

        function delete(obj)

            obj.stopSweeping();

            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                delete(obj.Timer);
            end

            if ~isempty(obj.Driver)
                try
                    obj.Driver.disconnect();
                catch
                end
            end

            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                delete(obj.Figure);
            end

        end

    end

    %==============================================================
    % VNA CONNECTION
    %==============================================================
    methods

        function connectVNA(obj)
            % Find VNAs, pick one, connect. Shows a progress dialog.

            obj.stopSweeping();

            dlg = uiprogressdlg(obj.Figure, 'Title', 'Connecting to VNA', ...
                'Message', 'Searching for VNA...', 'Indeterminate', 'on');

            cleanup = onCleanup(@() delete(dlg));

            if ~isempty(obj.Driver)
                try
                    obj.Driver.disconnect();
                catch
                end
                obj.Driver = [];
            end

            obj.VNAInfo = struct('Model', "", 'Resource', "", 'IDN', "");

            obj.CalVerified = false;

            while true

                found = VNA.Utilities.DiscoverVNAs( ...
                    Resources = obj.Settings.VNAResource, ...
                    IncludeSim = obj.IncludeSim, ...
                    ProgressFcn = @(m) set(dlg, 'Message', m));

                if height(found) >= 1
                    break
                end

                choice = obj.confirm( ...
                    ['No VNA was found. Check that it is on and connected ' ...
                    '(USB or network), then retry.'], 'No VNA Found', ...
                    ["Retry","Enter Address...","Work Offline"], "Retry");

                if choice == "Enter Address..."

                    address = obj.promptText('VNA Address', ...
                        'VISA resource, e.g. TCPIP0::192.168.1.200::5025::SOCKET', ...
                        obj.Settings.VNAResource);

                    if strlength(address) > 0

                        found = VNA.Utilities.DiscoverVNAs(Resources = address, ...
                            UseKnownResources = false, UseVisaDiscovery = false);

                        if height(found) >= 1
                            break
                        end

                        obj.alert(sprintf('No known VNA answered at %s.', address), ...
                            'VNA Not Found');

                    end

                elseif choice ~= "Retry"

                    obj.setStatus("Working offline: no VNA connected.");
                    obj.refresh();
                    return

                end

            end

            pick = 1;

            if height(found) > 1

                labels = found.Model + "  " + found.Resource;

                choice = obj.confirm('More than one VNA was found. Which one?', ...
                    'Choose VNA', labels(1:min(4,end)), labels(1));

                pick = find(labels == choice, 1);

            end

            dlg.Message = "Connecting to " + found.Model(pick) + "...";

            try

                cfg = VNA.Utilities.LoadVNAConfig(found.Model(pick));

                cfg.ConnectionAddress = found.Resource(pick);

                if found.Model(pick) == "SIM"
                    cfg.SimResponse = "Bandpass";
                end

                driver = VNA.VNAFactory.create(cfg);

                driver.connect();

                obj.Driver = driver;

                obj.VNAInfo = struct('Model', found.Model(pick), ...
                    'Resource', found.Resource(pick), 'IDN', found.IDN(pick));

                obj.Settings.VNAResource = found.Resource(pick);
                obj.Settings.save();

                obj.setStatus("Connected to " + found.Model(pick) + ".");

            catch ME

                obj.alert(ME.message, 'VNA Connection Error');

            end

            obj.refresh();

        end

    end

    %==============================================================
    % BATCH
    %==============================================================
    methods

        function startBatch(obj)

            if isempty(obj.Driver)
                obj.alert('Connect a VNA before starting a batch.', 'No VNA');
                return
            end

            profile = obj.selectedProfile();

            operator = strtrim(string(obj.H.Operator.Value));
            workOrder = strtrim(string(obj.H.WorkOrder.Value));
            serial = strtrim(string(obj.H.StartSerial.Value));

            if isempty(profile)
                obj.alert('Choose a part profile.', 'Start Batch');
                return
            end

            if strlength(operator) == 0
                obj.alert('Enter the operator name or ID.', 'Start Batch');
                return
            end

            if ~CATS.SerialNumber.isValid(serial)
                obj.alert(['The starting serial number must end in a number ' ...
                    '(e.g. 1235-0001) and contain no spaces or / \ : * ? " < > |.'], ...
                    'Start Batch');
                return
            end

            obj.Batch = CATS.Storage.newBatch(obj.Settings.DataRoot, ...
                profile, operator, workOrder);

            obj.Serial = serial;
            obj.ResumeSerial = "";
            obj.Records = struct([]);
            obj.LastSweep = [];
            obj.LastResults = table();
            obj.OverrideStatements = struct();

            obj.Settings.LastOperator = operator;
            obj.Settings.LastWorkOrder = workOrder;
            obj.Settings.LastProfile = profile.Name;
            obj.Settings.save();

            obj.preparePlot();
            obj.updateLog();
            obj.refresh();

            obj.setupVNA();

        end

        function finishBatch(obj)

            if isempty(obj.Batch)
                return
            end

            obj.stopSweeping();

            tested = ~isempty(obj.Records) && any([obj.Records.Decision] ~= "SKIPPED");

            if ~tested

                choice = obj.confirm('No parts were tested. End the batch anyway?', ...
                    'Finish Batch', ["End Batch","Cancel"], "Cancel");

                if choice ~= "End Batch"
                    return
                end

            else

                try

                    file = obj.writeBatchReport(obj.Batch);

                    choice = obj.confirm(sprintf('Batch report written:\n\n%s', file), ...
                        'Batch Finished', ["Open Folder","OK"], "OK");

                    if choice == "Open Folder"
                        obj.openFolder(fileparts(file));
                    end

                catch ME

                    obj.alert(sprintf('The batch report could not be written:\n\n%s', ...
                        ME.message), 'Report Error');

                end

            end

            obj.H.StartSerial.Value = char(obj.Serial);

            obj.Batch = struct([]);
            obj.CalVerified = false;
            obj.LastSweep = [];
            obj.LastResults = table();

            obj.setStatus("Batch finished.");
            obj.refresh();

        end

    end

    %==============================================================
    % VNA SETUP AND CALIBRATION
    %==============================================================
    methods

        function setupVNA(obj)
            % Push the profile's sweep, prompt for ECal, then verify.

            if isempty(obj.Batch) || isempty(obj.Driver)
                return
            end

            obj.stopSweeping();

            p = obj.Batch.Profile;

            dlg = uiprogressdlg(obj.Figure, 'Title', 'VNA Setup', ...
                'Message', "Setting up the VNA for " + p.Name + "...", ...
                'Indeterminate', 'on');

            try

                obj.Driver.Config.Ports = p.Ports;

                % Simulated VNA: make the simulated part a golden unit
                if ismethod(obj.Driver, 'tuneToProfile') && p.PartType == "Filter"
                    obj.Driver.tuneToProfile(p);
                end

                obj.Driver.pushStimulus(struct( ...
                    'StartFreq', p.Stimulus.StartHz, ...
                    'StopFreq', p.Stimulus.StopHz, ...
                    'NumPoints', p.Stimulus.Points, ...
                    'IFBW', p.Stimulus.IFBWHz, ...
                    'Power', p.Stimulus.PowerdBm));

            catch ME

                delete(dlg);

                obj.CalVerified = false;
                obj.setCalStatus(false, "VNA setup failed: " + ME.message);
                obj.refresh();

                return

            end

            delete(dlg);

            ports = strjoin(string(p.Ports), ", ");

            choice = obj.confirm(sprintf([ ...
                'The VNA is set up for %s.\n\n' ...
                '1. Connect the ECal module to ports %s.\n' ...
                '2. On the VNA, run a full %d-port ECal (keep the current sweep settings).\n' ...
                '3. Reconnect the test fixture.\n\n' ...
                'Click Done when the ECal has finished.'], ...
                p.Name, ports, numel(p.Ports)), 'Run ECal', ...
                ["Done","Use Existing Cal","Cancel"], "Done");

            if choice == "Cancel"

                obj.setCalStatus(false, "ECal not run. Click Set Up VNA + ECal.");
                obj.refresh();

                return

            end

            obj.verifyCal();

        end

        function ok = verifyCal(obj)
            % Testing is allowed only when the VNA sweep matches the
            % profile and error correction is on for every parameter.

            ok = false;

            if isempty(obj.Batch) || isempty(obj.Driver)
                return
            end

            p = obj.Batch.Profile;

            reasons = strings(0,1);

            try

                s = obj.Driver.readInstrumentSettings();

                if abs(s.StartFreq - p.Stimulus.StartHz) > 1 || ...
                        abs(s.StopFreq - p.Stimulus.StopHz) > 1 || ...
                        s.NumPoints ~= p.Stimulus.Points

                    reasons(end+1) = sprintf( ...
                        'VNA sweep is %.6g-%.6g MHz, %d points; profile needs %.6g-%.6g MHz, %d points.', ...
                        s.StartFreq/1e6, s.StopFreq/1e6, s.NumPoints, ...
                        p.Stimulus.StartHz/1e6, p.Stimulus.StopHz/1e6, p.Stimulus.Points);

                end

                if abs(s.IFBW - p.Stimulus.IFBWHz) > 0.01*p.Stimulus.IFBWHz
                    reasons(end+1) = sprintf('IF bandwidth is %g Hz; profile needs %g Hz.', ...
                        s.IFBW, p.Stimulus.IFBWHz);
                end

                cal = obj.Driver.getCalInfo();

                if ~cal.CorrectionOn

                    off = cal.Parameters(~cal.ParameterOn);

                    reasons(end+1) = "Error correction is OFF for " + ...
                        strjoin(off, ", ") + ". Run ECal.";

                end

                obj.CalInfo = cal;

            catch ME

                reasons(end+1) = "Could not read the VNA: " + ME.message;

            end

            ok = isempty(reasons);

            obj.CalVerified = ok;

            if ok

                name = obj.CalInfo.Calset;

                if strlength(name) == 0
                    name = "active cal";
                end

                obj.setCalStatus(true, "Cal verified " + ...
                    string(datetime("now"), "HH:mm") + "  (" + name + ")");

                obj.setStatus("Connect the part and press Start.");

            else

                obj.setCalStatus(false, strjoin(reasons, newline));

            end

            obj.refresh();

        end

    end

    %==============================================================
    % SWEEPING AND DECISIONS
    %==============================================================
    methods

        function startSweeping(obj)

            if obj.Sweeping || ~obj.canTest()
                return
            end

            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                delete(obj.Timer);
            end

            % fixedSpacing: the gap is measured from the END of each
            % sweep, so a slow sweep can never monopolize MATLAB
            obj.Timer = timer('ExecutionMode', 'fixedSpacing', ...
                'Period', max(0.3, obj.SweepGapSec), 'BusyMode', 'drop', ...
                'TimerFcn', @(~,~) obj.sweepOnce(), ...
                'Name', 'CATS sweep');

            obj.Sweeping = true;

            start(obj.Timer);

            obj.setStatus("Sweeping. Adjust the part, then PASS or FAIL.");

            obj.refresh();

        end

        function stopSweeping(obj)

            if ~isempty(obj.Timer) && isvalid(obj.Timer) && ...
                    strcmp(obj.Timer.Running, 'on')

                stop(obj.Timer);

            end

            if obj.Sweeping

                obj.Sweeping = false;

                if ~isempty(obj.Figure) && isvalid(obj.Figure)
                    obj.setStatus("Sweeping stopped. Press Start to resume.");
                    obj.refresh();
                end

            end

        end

        function sweepOnce(obj)
            % One live measurement: acquire, evaluate, display.

            if isempty(obj.Batch) || isempty(obj.Driver)
                return
            end

            try

                sObj = obj.Driver.acquire();

                results = Specs.evaluate(sObj, obj.Batch.Profile);

            catch ME

                obj.stopSweeping();

                obj.alert(sprintf('The VNA sweep failed:\n\n%s', ME.message), ...
                    'Sweep Error');

                return

            end

            if ~isvalid(obj.Figure)
                return
            end

            obj.LastSweep = sObj;
            obj.LastResults = results;

            obj.showSweep(sObj, results);

            obj.refreshDecisionButtons();

            % Let button clicks (Stop, PASS, FAIL) through promptly
            drawnow limitrate;

        end

        function record(obj, decision)
            % Save the evaluated sweep as PASS or FAIL and move to the
            % next serial number.

            arguments
                obj
                decision {mustBeMember(decision, ["PASS","FAIL"])}
            end

            if isempty(obj.Batch) || isempty(obj.LastSweep)
                return
            end

            [canPass, overridden] = obj.passState();

            if decision == "PASS" && ~canPass
                return
            end

            wasSweeping = obj.Sweeping;

            obj.stopSweeping();

            sObj = obj.LastSweep;
            results = obj.LastResults;

            %
            % PASS with failing overridable criteria needs a statement.
            % It is asked for once per criterion and reused part to part.
            %
            override = "";

            if decision == "PASS" && ~isempty(overridden)

                notes = strings(0,1);

                for id = overridden(:).'

                    statement = obj.overrideStatementFor(id, results);

                    if strlength(statement) == 0

                        obj.setStatus("PASS w/ Override cancelled: a statement is required.");

                        if wasSweeping
                            obj.startSweeping();
                        end

                        return

                    end

                    notes(end+1) = id + ": " + statement; %#ok<AGROW>

                end

                override = strjoin(notes, "; ");

            end

            retest = ~isempty(obj.Records) && any( ...
                [obj.Records.Serial] == obj.Serial & ...
                [obj.Records.Decision] ~= "SKIPPED");

            if retest

                choice = obj.confirm(sprintf( ...
                    '%s has already been tested in this batch. Save this as a retest?', ...
                    obj.Serial), 'Retest', ["Save Retest","Cancel"], "Cancel");

                if choice ~= "Save Retest"

                    if wasSweeping
                        obj.startSweeping();
                    end

                    return

                end

            end

            info = struct( ...
                'Retest', retest, ...
                'Override', override, ...
                'Software', "CATS " + CATS.App.Version, ...
                'VNA', obj.VNAInfo, ...
                'Calibration', obj.CalInfo);

            try

                rec = CATS.Storage.saveRecord(obj.Batch, obj.Serial, sObj, ...
                    results, decision, info);

            catch ME

                obj.alert(sprintf('The sweep could not be saved:\n\n%s', ME.message), ...
                    'Save Error');

                return

            end

            obj.addLogEntry(rec.Serial, rec.Decision, rec.ComputedPass, rec.Retest, ...
                rec.Timestamp, rec.Override);

            saved = obj.Serial;

            % After a retest, go back to where the batch had got to
            if retest && strlength(obj.ResumeSerial) > 0
                obj.Serial = obj.ResumeSerial;
            else
                obj.Serial = CATS.SerialNumber.next(obj.Serial);
            end

            obj.ResumeSerial = "";

            obj.LastSweep = [];
            obj.LastResults = table();

            if strlength(override) > 0
                decision = decision + " (override " + strjoin(overridden, ",") + ")";
            end

            obj.setStatus(sprintf('Saved %s: %s.  Connect %s.', saved, decision, obj.Serial));

            obj.refresh();

            if wasSweeping
                obj.startSweeping();
            end

        end

        function skip(obj)
            % No part with this serial: log it and move on.

            if isempty(obj.Batch)
                return
            end

            CATS.Storage.logSkip(obj.Batch, obj.Serial);

            obj.addLogEntry(obj.Serial, "SKIPPED", false, false, datetime("now"));

            skipped = obj.Serial;

            obj.Serial = CATS.SerialNumber.next(obj.Serial);

            obj.setStatus(sprintf('Skipped %s.  Connect %s.', skipped, obj.Serial));

            obj.refresh();

        end

        function setSerial(obj, serial)

            serial = strtrim(string(serial));

            if ~CATS.SerialNumber.isValid(serial)

                obj.alert(['A serial number must end in a number and contain ' ...
                    'no spaces or / \ : * ? " < > |.'], 'Serial Number');

                return

            end

            % Going back to a part already tested: remember where the
            % batch had got to, and return there after the retest
            tested = ~isempty(obj.Records) && any([obj.Records.Serial] == serial & ...
                [obj.Records.Decision] ~= "SKIPPED");

            if tested && strlength(obj.ResumeSerial) == 0
                obj.ResumeSerial = obj.Serial;
            elseif ~tested
                obj.ResumeSerial = "";
            end

            obj.Serial = serial;

            obj.setStatus("Serial set to " + serial + ".");

            obj.refresh();

        end

    end

    %==============================================================
    % REPORTS AND REVIEW
    %==============================================================
    methods

        function file = writeBatchReport(obj, batch)

            records = CATS.Storage.readRecords(batch.Root, ...
                BatchId = batch.Id, From = batch.Start - hours(1));

            records = CATS.Storage.latestPerSerial(records);

            if isempty(records)
                error('CATS:NoRecords', 'No saved parts in batch %s.', batch.Id);
            end

            file = batch.ReportFile;

            Specs.writeReport(records, batch.Profile, file, ...
                obj.reportHeader(records));

        end

        function file = writeRangeReport(obj, profileName, from, to, operator)

            profile = obj.profileByName(profileName);

            records = CATS.Storage.readRecords(obj.Settings.DataRoot, ...
                From = from, To = to, Profile = profileName, Operator = operator);

            records = CATS.Storage.latestPerSerial(records);

            if isempty(records)
                error('CATS:NoRecords', 'No %s parts were tested in that period.', profileName);
            end

            folder = fullfile(obj.Settings.DataRoot, "Reports");

            CATS.Storage.ensureFolder(folder);

            name = sprintf('Report_%s_%s_to_%s', profileName, ...
                string(from, "yyyyMMdd_HHmm"), string(to, "yyyyMMdd_HHmm"));

            if strlength(operator) > 0
                name = name + "_" + regexprep(operator, '[<>:"/\\|?*\s]', '_');
            end

            file = fullfile(folder, name + ".xlsx");

            Specs.writeReport(records, profile, file, obj.reportHeader(records));

        end

        function loadReviewFiles(obj, files)
            % Load Touchstone files for review (metadata used if found).

            files = string(files);

            items = struct([]);

            for f = files(:).'

                try
                    sObj = sparameters(f);
                catch ME
                    obj.alert(sprintf('%s could not be read:\n%s', f, ME.message), 'Review');
                    continue
                end

                [folder, name] = fileparts(f);

                meta = CATS.Storage.readRecord(fullfile(fileparts(folder), ...
                    "Metadata", name + ".json"));

                item = struct('File', f, 'Name', name, 'SParams', sObj, 'Record', {meta});

                if isempty(items)
                    items = item;
                else
                    items(end+1) = item; %#ok<AGROW>
                end

            end

            obj.ReviewItems = items;

            if isempty(items)
                obj.H.ReviewList.Items = {};
                obj.updateReview();
                return
            end

            obj.H.ReviewList.Items = cellstr([items.Name]);
            obj.H.ReviewList.ItemsData = 1:numel(items);
            obj.H.ReviewList.Value = 1:numel(items);

            % Default the profile from the first file's metadata
            first = items(1).Record;

            if ~isempty(first) && any(strcmp(obj.H.ReviewProfile.Items, first.Profile))
                obj.H.ReviewProfile.Value = char(first.Profile);
            end

            obj.updateReview();

        end

    end

    %==============================================================
    % UI CONSTRUCTION
    %==============================================================
    methods (Access = private)

        function buildUI(obj)

            fig = uifigure('Name', 'CATS - Acceptance Test System', ...
                'Position', [60 60 1366 820], 'Visible', 'off', ...
                'Theme', obj.Settings.Theme, 'Tag', 'CATS_Figure');

            logo = fullfile(CATS.App.appFolder(), 'CTSLogoPSS.png');

            if isfile(logo)
                fig.Icon = logo;
            end

            fig.CloseRequestFcn = @(~,~) obj.onClose();

            fig.ThemeChangedFcn = @(~,~) obj.onThemeChanged();

            obj.Figure = fig;

            main = uigridlayout(fig, [3 1]);
            main.RowHeight = {48, '1x', 30};
            main.Padding = [12 8 12 6];
            main.RowSpacing = 6;

            obj.buildHeader(main);

            tabs = uitabgroup(main);
            tabs.Layout.Row = 2;
            tabs.SelectionChangedFcn = @(~,e) obj.onTabChanged(e.NewValue);

            obj.H.Tabs = tabs;

            obj.buildTestTab(uitab(tabs, 'Title', 'Test'));
            obj.buildLogTab(uitab(tabs, 'Title', 'Log'));
            obj.buildReviewTab(uitab(tabs, 'Title', 'Review'));
            obj.buildReportsTab(uitab(tabs, 'Title', 'Reports'));

            obj.H.Status = uilabel(main, 'Text', 'Starting...', ...
                'FontSize', CATS.Theme.FontBase);
            obj.H.Status.Layout.Row = 3;

            obj.tagComponents();

        end

        function buildHeader(obj, parent)

            g = uigridlayout(parent, [1 7]);
            g.Layout.Row = 1;
            g.ColumnWidth = {44, 'fit', '1x', 24, 'fit', 'fit', 'fit'};
            g.Padding = [0 4 0 4];
            g.ColumnSpacing = 10;

            logo = fullfile(CATS.App.appFolder(), 'CTSLogoPSS.png');

            img = uiimage(g);

            if isfile(logo)
                img.ImageSource = logo;
            end

            title = uilabel(g, 'Text', "Acceptance Test System", ...
                'FontSize', CATS.Theme.FontHeading, 'FontWeight', 'bold');
            title.Layout.Column = 2;

            obj.H.VNALamp = uilamp(g);
            obj.H.VNALamp.Layout.Column = 4;

            obj.H.VNALabel = uilabel(g, 'Text', 'No VNA', 'FontSize', CATS.Theme.FontBase);
            obj.H.VNALabel.Layout.Column = 5;

            obj.H.Connect = uibutton(g, 'Text', 'Connect VNA', ...
                'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) obj.connectVNA());
            obj.H.Connect.Layout.Column = 6;

            right = uigridlayout(g, [1 3]);
            right.Layout.Column = 7;
            right.ColumnWidth = {'fit', 90, 'fit'};
            right.Padding = [0 0 0 0];

            obj.H.ThemeSwitch = uiswitch(right, 'slider', ...
                'Items', {'Light','Dark'}, 'FontSize', CATS.Theme.FontBase, ...
                'Value', char(upper(extractBefore(obj.Settings.Theme,2)) + extractAfter(obj.Settings.Theme,1)), ...
                'ValueChangedFcn', @(s,~) obj.setTheme(lower(string(s.Value))));
            obj.H.ThemeSwitch.Layout.Column = 2;

            obj.H.SettingsButton = uibutton(right, 'Text', 'Settings', ...
                'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) obj.openSettings());
            obj.H.SettingsButton.Layout.Column = 3;

        end

        function buildTestTab(obj, tab)

            g = uigridlayout(tab, [1 2]);
            g.ColumnWidth = {390, '1x'};
            g.Padding = [10 10 10 10];
            g.ColumnSpacing = 12;

            %
            % Left column: batch, calibration, part under test
            %
            left = uigridlayout(g, [3 1]);
            left.RowHeight = {'fit', 'fit', '1x'};
            left.Padding = [0 0 0 0];
            left.RowSpacing = 10;

            p = uipanel(left, 'Title', 'Batch', 'FontSize', CATS.Theme.FontLarge, ...
                'FontWeight', 'bold');

            b = uigridlayout(p, [6 2]);
            b.ColumnWidth = {120, '1x'};
            b.RowHeight = {32, 'fit', 32, 32, 32, 44};
            b.RowSpacing = 8;

            obj.label(b, 'Part', 1, 1);
            obj.H.Profile = uidropdown(b, 'Items', {}, 'FontSize', CATS.Theme.FontBase, ...
                'ValueChangedFcn', @(~,~) obj.refresh());
            obj.place(obj.H.Profile, 1, 2);

            obj.H.ProfileInfo = uilabel(b, 'Text', '', 'WordWrap', 'on', ...
                'FontSize', 12, 'FontAngle', 'italic');
            obj.place(obj.H.ProfileInfo, 2, [1 2]);

            obj.label(b, 'Operator', 3, 1);
            obj.H.Operator = uieditfield(b, 'text', 'FontSize', CATS.Theme.FontBase, ...
                'Value', char(obj.Settings.LastOperator));
            obj.place(obj.H.Operator, 3, 2);

            obj.label(b, 'Work Order', 4, 1);
            obj.H.WorkOrder = uieditfield(b, 'text', 'FontSize', CATS.Theme.FontBase, ...
                'Value', char(obj.Settings.LastWorkOrder));
            obj.place(obj.H.WorkOrder, 4, 2);

            obj.label(b, 'First Serial', 5, 1);
            obj.H.StartSerial = uieditfield(b, 'text', 'FontSize', CATS.Theme.FontBase, ...
                'Placeholder', 'e.g. 1235-0001');
            obj.place(obj.H.StartSerial, 5, 2);

            bb = uigridlayout(b, [1 2]);
            bb.Padding = [0 0 0 0];
            obj.place(bb, 6, [1 2]);

            obj.H.StartBatch = uibutton(bb, 'Text', 'Start Batch', ...
                'FontSize', CATS.Theme.FontLarge, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) obj.startBatch());

            obj.H.FinishBatch = uibutton(bb, 'Text', 'Finish Batch', ...
                'FontSize', CATS.Theme.FontLarge, ...
                'ButtonPushedFcn', @(~,~) obj.finishBatch());

            p = uipanel(left, 'Title', 'Calibration', 'FontSize', CATS.Theme.FontLarge, ...
                'FontWeight', 'bold');

            c = uigridlayout(p, [2 2]);
            c.ColumnWidth = {28, '1x'};
            c.RowHeight = {'fit', 40};

            obj.H.CalLamp = uilamp(c);
            obj.H.CalLamp.Layout.Row = 1;
            obj.H.CalLamp.Layout.Column = 1;

            obj.H.CalLabel = uilabel(c, 'Text', 'Start a batch to set up the VNA.', ...
                'WordWrap', 'on', 'FontSize', CATS.Theme.FontBase);
            obj.place(obj.H.CalLabel, 1, 2);

            cb = uigridlayout(c, [1 2]);
            cb.Padding = [0 0 0 0];
            obj.place(cb, 2, [1 2]);

            obj.H.SetupVNA = uibutton(cb, 'Text', 'Set Up VNA + ECal', ...
                'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) obj.setupVNA());

            obj.H.VerifyCal = uibutton(cb, 'Text', 'Re-verify Cal', ...
                'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) obj.verifyCal());

            p = uipanel(left, 'Title', 'Part Under Test', 'FontSize', CATS.Theme.FontLarge, ...
                'FontWeight', 'bold');

            s = uigridlayout(p, [4 2]);
            s.RowHeight = {64, 44, '1x', 'fit'};
            s.RowSpacing = 10;

            obj.H.Serial = uieditfield(s, 'text', 'Editable', 'off', ...
                'FontSize', CATS.Theme.FontSerial, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center', ...
                'ValueChangedFcn', @(f,~) obj.onSerialEdited(f.Value));
            obj.place(obj.H.Serial, 1, [1 2]);

            obj.H.Skip = uibutton(s, 'Text', 'Skip', 'FontSize', CATS.Theme.FontLarge, ...
                'Tooltip', 'No part with this serial: log it as skipped and go to the next', ...
                'ButtonPushedFcn', @(~,~) obj.skip());
            obj.place(obj.H.Skip, 2, 1);

            obj.H.SetSerial = uibutton(s, 'Text', 'Set Serial...', ...
                'FontSize', CATS.Theme.FontLarge, ...
                'ButtonPushedFcn', @(~,~) obj.onSetSerial());
            obj.place(obj.H.SetSerial, 2, 2);

            obj.H.Guide = uilabel(s, 'Text', '', 'WordWrap', 'on', ...
                'FontSize', CATS.Theme.FontLarge, 'VerticalAlignment', 'top');
            obj.place(obj.H.Guide, 3, [1 2]);

            %
            % Override statement in use (carried from part to part)
            %
            o = uigridlayout(s, [1 2]);
            o.ColumnWidth = {'1x', 70};
            o.Padding = [0 0 0 0];
            obj.place(o, 4, [1 2]);

            obj.H.OverrideNote = uilabel(o, 'Text', '', 'WordWrap', 'on', ...
                'FontSize', 13, 'FontAngle', 'italic');

            obj.H.EditOverride = uibutton(o, 'Text', 'Edit...', 'FontSize', 13, ...
                'Tooltip', 'Change the override statement used for the rest of this batch', ...
                'ButtonPushedFcn', @(~,~) obj.editOverrideStatements());

            %
            % Right column: plot + criteria, then the big buttons
            %
            right = uigridlayout(g, [2 1]);
            right.RowHeight = {'1x', 96};
            right.Padding = [0 0 0 0];
            right.RowSpacing = 10;

            top = uigridlayout(right, [1 2]);
            top.ColumnWidth = {'1x', 520};
            top.Padding = [0 0 0 0];

            %
            % Wideband (full sweep) on top, passband zoom below; both live
            %
            plotGrid = uigridlayout(top, [2 1]);
            plotGrid.RowHeight = {'1x', '1x'};
            plotGrid.Padding = [0 0 0 0];
            plotGrid.RowSpacing = 4;

            obj.H.Axes = uiaxes(plotGrid, 'FontSize', 12);
            ylabel(obj.H.Axes, 'Magnitude (dB)');
            grid(obj.H.Axes, 'on');

            obj.H.NarrowAxes = uiaxes(plotGrid, 'FontSize', 12);
            xlabel(obj.H.NarrowAxes, 'Frequency (MHz)');
            ylabel(obj.H.NarrowAxes, 'Magnitude (dB)');
            grid(obj.H.NarrowAxes, 'on');

            obj.H.Criteria = uitable(top, 'FontSize', 16, 'RowName', {}, ...
                'ColumnName', {'Criterion','Value','Limit','Result'}, ...
                'ColumnWidth', {'5x', '3x', '3x', '2x'}, ...
                'Data', cell(0,4));

            bottom = uigridlayout(right, [1 3]);
            bottom.ColumnWidth = {'1x', '1.3x', '1.3x'};
            bottom.Padding = [0 0 0 0];
            bottom.ColumnSpacing = 14;

            obj.H.Sweep = uibutton(bottom, 'Text', 'Start', ...
                'FontSize', 26, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) obj.onSweepButton());

            obj.H.Pass = uibutton(bottom, 'Text', 'PASS', ...
                'FontSize', CATS.Theme.FontDecision, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) obj.record("PASS"));

            obj.H.Fail = uibutton(bottom, 'Text', 'FAIL', ...
                'FontSize', CATS.Theme.FontDecision, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) obj.record("FAIL"));

        end

        function buildLogTab(obj, tab)

            g = uigridlayout(tab, [2 2]);
            g.RowHeight = {40, '1x'};
            g.ColumnWidth = {'1x', 'fit'};
            g.Padding = [10 10 10 10];

            obj.H.LogSummary = uilabel(g, 'Text', 'No batch running.', ...
                'FontSize', CATS.Theme.FontLarge, 'FontWeight', 'bold');

            obj.H.OpenData = uibutton(g, 'Text', 'Open Data Folder', ...
                'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) obj.openFolder(obj.Settings.DataRoot));

            obj.H.Log = uitable(g, 'FontSize', 16, 'RowName', {}, ...
                'ColumnName', {'Time','Serial','Result','Criteria','Retest'}, ...
                'ColumnWidth', {120, '1x', 120, 120, 90}, ...
                'Data', cell(0,5));
            obj.place(obj.H.Log, 2, [1 2]);

        end

        function buildReviewTab(obj, tab)

            g = uigridlayout(tab, [1 2]);
            g.ColumnWidth = {340, '1x'};
            g.Padding = [10 10 10 10];
            g.ColumnSpacing = 12;

            left = uigridlayout(g, [6 1]);
            left.RowHeight = {44, 32, 32, 32, '1x', 'fit'};
            left.Padding = [0 0 0 0];

            uibutton(left, 'Text', 'Load Touchstone Files...', ...
                'FontSize', CATS.Theme.FontLarge, ...
                'ButtonPushedFcn', @(~,~) obj.onLoadReview(), 'Tag', 'CATS_ReviewLoad');

            uilabel(left, 'Text', 'Judge against part profile:', 'FontSize', CATS.Theme.FontBase);

            obj.H.ReviewProfile = uidropdown(left, 'Items', {}, ...
                'FontSize', CATS.Theme.FontBase, 'ValueChangedFcn', @(~,~) obj.updateReview());

            uilabel(left, 'Text', 'Files (select to plot):', 'FontSize', CATS.Theme.FontBase);

            obj.H.ReviewList = uilistbox(left, 'Items', {}, 'Multiselect', 'on', ...
                'FontSize', CATS.Theme.FontBase, 'ValueChangedFcn', @(~,~) obj.updateReview());

            obj.H.ReviewInfo = uilabel(left, 'Text', '', 'WordWrap', 'on', ...
                'FontSize', CATS.Theme.FontBase);

            right = uigridlayout(g, [1 2]);
            right.ColumnWidth = {'1x', 400};
            right.Padding = [0 0 0 0];

            obj.H.ReviewAxes = uiaxes(right, 'FontSize', 13);
            xlabel(obj.H.ReviewAxes, 'Frequency (MHz)');
            ylabel(obj.H.ReviewAxes, 'Magnitude (dB)');
            grid(obj.H.ReviewAxes, 'on');

            obj.H.ReviewCriteria = uitable(right, 'FontSize', 16, 'RowName', {}, ...
                'ColumnName', {'Criterion','Value','Limit','Result'}, ...
                'ColumnWidth', {150, 90, 100, 60}, 'Data', cell(0,4));

        end

        function buildReportsTab(obj, tab)

            g = uigridlayout(tab, [3 1]);
            g.RowHeight = {'fit', 'fit', '1x'};
            g.Padding = [10 10 10 10];
            g.RowSpacing = 14;

            %
            % Batch report
            %
            p = uipanel(g, 'Title', 'Batch Report', 'FontSize', CATS.Theme.FontLarge, ...
                'FontWeight', 'bold');

            b = uigridlayout(p, [1 3]);
            b.ColumnWidth = {120, '1x', 220};
            b.RowHeight = {36};

            obj.label(b, 'Batch', 1, 1);

            obj.H.BatchList = uidropdown(b, 'Items', {}, 'FontSize', CATS.Theme.FontBase);
            obj.place(obj.H.BatchList, 1, 2);

            obj.H.WriteBatchReport = uibutton(b, 'Text', 'Write Batch Report', ...
                'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) obj.onWriteBatchReport());
            obj.place(obj.H.WriteBatchReport, 1, 3);

            %
            % Day / shift report
            %
            p = uipanel(g, 'Title', 'Day / Shift Report', 'FontSize', CATS.Theme.FontLarge, ...
                'FontWeight', 'bold');

            d = uigridlayout(p, [3 5]);
            d.ColumnWidth = {120, 180, 90, 120, '1x'};
            d.RowHeight = {36, 36, 40};

            obj.label(d, 'From', 1, 1);
            obj.H.FromDate = uidatepicker(d, 'Value', datetime("today"), ...
                'FontSize', CATS.Theme.FontBase, 'DisplayFormat', 'yyyy-MM-dd');
            obj.place(obj.H.FromDate, 1, 2);
            obj.H.FromTime = uieditfield(d, 'text', 'Value', '00:00', ...
                'FontSize', CATS.Theme.FontBase, 'Tooltip', 'HH:mm (24 h)');
            obj.place(obj.H.FromTime, 1, 3);

            obj.label(d, 'Part', 1, 4);
            obj.H.ReportProfile = uidropdown(d, 'Items', {}, 'FontSize', CATS.Theme.FontBase);
            obj.place(obj.H.ReportProfile, 1, 5);

            obj.label(d, 'To', 2, 1);
            obj.H.ToDate = uidatepicker(d, 'Value', datetime("today"), ...
                'FontSize', CATS.Theme.FontBase, 'DisplayFormat', 'yyyy-MM-dd');
            obj.place(obj.H.ToDate, 2, 2);
            obj.H.ToTime = uieditfield(d, 'text', 'Value', '23:59', ...
                'FontSize', CATS.Theme.FontBase, 'Tooltip', 'HH:mm (24 h)');
            obj.place(obj.H.ToTime, 2, 3);

            obj.label(d, 'Operator', 2, 4);
            obj.H.ReportOperator = uidropdown(d, 'Items', {'All operators'}, ...
                'FontSize', CATS.Theme.FontBase);
            obj.place(obj.H.ReportOperator, 2, 5);

            obj.H.WriteRangeReport = uibutton(d, 'Text', 'Write Report', ...
                'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) obj.onWriteRangeReport());
            obj.place(obj.H.WriteRangeReport, 3, 5);

            obj.H.ReportStatus = uilabel(g, 'Text', '', 'WordWrap', 'on', ...
                'FontSize', CATS.Theme.FontBase, 'VerticalAlignment', 'top');

        end

        function tagComponents(obj)

            for name = string(fieldnames(obj.H)).'
                if isprop(obj.H.(name), 'Tag') && isempty(obj.H.(name).Tag)
                    obj.H.(name).Tag = "CATS_" + name;
                end
            end

        end

        function lbl = label(obj, grid, text, row, col)

            lbl = uilabel(grid, 'Text', text, 'FontSize', CATS.Theme.FontBase);

            obj.place(lbl, row, col);

        end

        function place(~, component, row, col)

            component.Layout.Row = row;
            component.Layout.Column = col;

        end

    end

    %==============================================================
    % STATE -> UI
    %==============================================================
    methods (Access = private)

        function refresh(obj)
            % Enable/disable and style everything from the current state.

            if isempty(obj.Figure) || ~isvalid(obj.Figure)
                return
            end

            connected = ~isempty(obj.Driver);
            batch = ~isempty(obj.Batch);

            %
            % Header
            %
            if connected
                CATS.Theme.style(obj.H.VNALamp, "success");
                obj.H.VNALabel.Text = obj.VNAInfo.Model + "   " + obj.VNAInfo.Resource;
                obj.H.VNALabel.Tooltip = obj.VNAInfo.IDN;
                CATS.Theme.style(obj.H.Connect, "auto");
                obj.H.Connect.Text = 'Reconnect';
            else
                CATS.Theme.style(obj.H.VNALamp, "warning");
                obj.H.VNALabel.Text = 'No VNA connected';
                CATS.Theme.style(obj.H.Connect, "primary");
                obj.H.Connect.Text = 'Connect VNA';
            end

            obj.H.Connect.Enable = ~obj.Sweeping;
            obj.H.SettingsButton.Enable = ~batch;

            %
            % Batch
            %
            profile = obj.selectedProfile();

            if ~isempty(profile)
                obj.H.ProfileInfo.Text = profile.Description + "   (" + ...
                    numel(profile.Criteria) + " criteria)";
            else
                obj.H.ProfileInfo.Text = "No part profiles found in " + obj.Settings.ProfilesFolder;
            end

            for f = ["Profile","Operator","WorkOrder","StartSerial"]
                obj.H.(f).Enable = ~batch;
            end

            obj.H.StartBatch.Enable = ~batch && connected;
            obj.H.FinishBatch.Enable = batch && ~obj.Sweeping;

            if batch
                CATS.Theme.style(obj.H.StartBatch, "success");
                obj.H.StartBatch.Text = 'Batch Running';
                CATS.Theme.style(obj.H.FinishBatch, "primary");
            else
                CATS.Theme.style(obj.H.StartBatch, "primary");
                obj.H.StartBatch.Text = 'Start Batch';
                CATS.Theme.style(obj.H.FinishBatch, "auto");
            end

            %
            % Calibration
            %
            obj.H.SetupVNA.Enable = batch && connected && ~obj.Sweeping;
            obj.H.VerifyCal.Enable = batch && connected && ~obj.Sweeping;

            if ~batch
                CATS.Theme.style(obj.H.CalLamp, "neutral");
                obj.H.CalLabel.Text = 'Start a batch to set up the VNA.';
            end

            %
            % Part under test
            %
            obj.H.Serial.Value = char(obj.Serial);
            obj.H.Skip.Enable = batch && ~obj.Sweeping;
            obj.H.SetSerial.Enable = batch && ~obj.Sweeping;

            if ~batch
                obj.H.Guide.Text = 'Choose the part, enter your name and the first serial number, then Start Batch.';
            elseif ~obj.CalVerified
                obj.H.Guide.Text = 'Calibration needed before testing.';
            elseif obj.Sweeping
                obj.H.Guide.Text = sprintf('Testing %s. Adjust the part until every criterion is green, then PASS. Use FAIL if it cannot pass.', obj.Serial);
            else
                obj.H.Guide.Text = sprintf('Connect %s and press Start.', obj.Serial);
            end

            %
            % Override statement(s) in use for this batch
            %
            ids = string(fieldnames(obj.OverrideStatements));

            if batch && ~isempty(ids)

                lines = ids + ": " + arrayfun(@(id) string(obj.OverrideStatements.(id)), ids);

                obj.H.OverrideNote.Text = "Override statement in use (* criteria):" + newline + strjoin(lines, newline);

                obj.H.EditOverride.Visible = 'on';

            else

                obj.H.OverrideNote.Text = '';

                obj.H.EditOverride.Visible = 'off';

            end

            obj.H.EditOverride.Enable = batch && ~obj.Sweeping;

            %
            % Big buttons
            %
            canTest = obj.canTest();

            obj.H.Sweep.Enable = canTest;

            if obj.Sweeping
                CATS.Theme.style(obj.H.Sweep, "success");
                obj.H.Sweep.Text = 'Stop';
            else
                CATS.Theme.style(obj.H.Sweep, "primary");
                obj.H.Sweep.Text = 'Start';
            end

            obj.refreshDecisionButtons();

            %
            % Profile lists on other tabs
            %
            names = {};
            if ~isempty(obj.Profiles)
                names = cellstr([obj.Profiles.Name]);
            end

            obj.setItems(obj.H.ReviewProfile, names);
            obj.setItems(obj.H.ReportProfile, names);

        end

        function refreshDecisionButtons(obj)

            have = ~isempty(obj.Batch) && ~isempty(obj.LastSweep) && obj.CalVerified;

            [canPass, overridden] = obj.passState();

            canPass = have && canPass;

            obj.H.Pass.Enable = canPass;
            obj.H.Fail.Enable = have;

            if canPass && isempty(overridden)
                CATS.Theme.style(obj.H.Pass, "success");
                obj.H.Pass.Text = 'PASS';
                obj.H.Pass.FontSize = CATS.Theme.FontDecision;
            elseif canPass
                CATS.Theme.style(obj.H.Pass, "success");
                obj.H.Pass.Text = 'PASS w/ Override';
                obj.H.Pass.FontSize = 26;
            else
                CATS.Theme.style(obj.H.Pass, "auto");
                obj.H.Pass.Text = 'PASS';
                obj.H.Pass.FontSize = CATS.Theme.FontDecision;
            end

            if have
                CATS.Theme.style(obj.H.Fail, "warning");
            else
                CATS.Theme.style(obj.H.Fail, "auto");
            end

        end

        function [canPass, overridden] = passState(obj)
            % PASS is allowed when every non-overridable criterion
            % passes. overridden lists failing overridable criteria
            % (empty for a clean PASS).

            canPass = false;
            overridden = strings(0,1);

            r = obj.LastResults;

            if isempty(r)
                return
            end

            canPass = ~any(~r.Pass & ~r.Overridable);

            overridden = r.Id(~r.Pass & r.Overridable);

        end

        function statement = overrideStatementFor(obj, id, results)
            % The statement for overriding criterion id: reused if one
            % was given earlier in this batch, otherwise asked for once
            % (pre-filled from the last one used, or the profile).

            if isfield(obj.OverrideStatements, id)
                statement = string(obj.OverrideStatements.(id));
                return
            end

            p = obj.Batch.Profile;

            c = p.Criteria([p.Criteria.Id] == id);

            default = obj.Settings.overrideStatement(p.Name, id);

            if strlength(default) == 0
                default = c.OverrideReason;
            end

            row = find(results.Id == id, 1);

            prompt = sprintf(['%s failed (%s, limit %s).\n' ...
                'Override statement (used for the rest of this batch):'], ...
                c.Label, CATS.App.formatValue(results.Value(row), results.Units(row)), ...
                CATS.App.formatLimit(results.Type(row), results.Limit(row), results.Units(row)));

            statement = strtrim(obj.promptText("PASS w/ Override", prompt, default));

            if strlength(statement) > 0
                obj.OverrideStatements.(id) = statement;
                obj.Settings.setOverrideStatement(p.Name, id, statement);
                obj.Settings.save();
                obj.refresh();
            end

        end

        function editOverrideStatements(obj)
            % Change the statement(s) in use for this batch.

            if isempty(obj.Batch)
                return
            end

            ids = string(fieldnames(obj.OverrideStatements));

            for id = ids(:).'

                text = strtrim(obj.promptText("Override Statement", ...
                    "Statement for overriding " + id + ":", obj.OverrideStatements.(id)));

                if strlength(text) > 0
                    obj.OverrideStatements.(id) = text;
                    obj.Settings.setOverrideStatement(obj.Batch.Profile.Name, id, text);
                end

            end

            obj.Settings.save();

            obj.refresh();

        end

        function tf = canTest(obj)

            tf = ~isempty(obj.Batch) && ~isempty(obj.Driver) && obj.CalVerified;

        end

        function setStatus(obj, text)

            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                obj.H.Status.Text = text;
            end

        end

        function setCalStatus(obj, ok, text)

            if ok
                CATS.Theme.style(obj.H.CalLamp, "success");
            else
                CATS.Theme.style(obj.H.CalLamp, "warning");
            end

            obj.H.CalLabel.Text = text;

        end

        function setItems(~, dropdown, items)

            current = dropdown.Value;

            dropdown.Items = items;

            % Value is {} when a dropdown has no items
            if ~isempty(items) && (ischar(current) || isstring(current)) && ...
                    any(strcmp(items, char(current)))
                dropdown.Value = current;
            end

        end

    end

    %==============================================================
    % PLOTTING AND CRITERIA DISPLAY
    %==============================================================
    methods (Access = private)

        function preparePlot(obj)
            % Wideband and passband plots, one line per trace in each,
            % updated in place every sweep.

            p = obj.Batch.Profile;

            [obj.WideLines, obj.NarrowLines] = deal(gobjects(0));

            axesList = [obj.H.Axes, obj.H.NarrowAxes];

            for a = 1:2

                ax = axesList(a);

                cla(ax);

                hold(ax, 'on');

                lines = gobjects(0);

                for t = obj.traceList(p)'
                    lines(end+1) = plot(ax, NaN, NaN, 'LineWidth', 1.6, ...
                        'LineStyle', t.Style, 'DisplayName', t.Name); %#ok<AGROW>
                end

                hold(ax, 'off');

                grid(ax, 'on');

                if a == 1
                    obj.WideLines = lines;
                else
                    obj.NarrowLines = lines;
                end

            end

            [wideX, narrowX, wideY, narrowY] = CATS.App.plotLimits(p);

            xlim(obj.H.Axes, wideX/1e6);
            ylim(obj.H.Axes, wideY);

            xlim(obj.H.NarrowAxes, narrowX/1e6);
            ylim(obj.H.NarrowAxes, narrowY);

            legend(obj.H.Axes, 'Location', 'southwest', 'FontSize', 11);

            title(obj.H.Axes, p.Name + "  " + p.Description + "   (full sweep)", 'FontSize', 13);
            title(obj.H.NarrowAxes, "Passband", 'FontSize', 13);

            obj.H.Criteria.Data = cell(0,4);

        end

        function traces = traceList(~, p)
            % Transmission solid, reflection dashed.

            n = numel(p.Ports);

            names = p.PortNames;

            traces = struct('Row', {}, 'Col', {}, 'Style', {}, 'Name', {});

            for r = 2:n
                traces(end+1) = struct('Row', r, 'Col', 1, 'Style', '-', ...
                    'Name', sprintf('S%d1 %s', r, names(r))); %#ok<AGROW>
            end

            for r = 1:n
                traces(end+1) = struct('Row', r, 'Col', r, 'Style', '--', ...
                    'Name', sprintf('S%d%d %s', r, r, names(r))); %#ok<AGROW>
            end

            traces = traces(:);

        end

        function showSweep(obj, sObj, results)

            p = obj.Batch.Profile;

            fMHz = sObj.Frequencies/1e6;

            traces = obj.traceList(p);

            for k = 1:numel(traces)

                d = 20*log10(abs(squeeze(sObj.Parameters(traces(k).Row, traces(k).Col, :))));

                for lines = {obj.WideLines, obj.NarrowLines}

                    h = lines{1};

                    if k <= numel(h) && isvalid(h(k))
                        set(h(k), 'XData', fMHz, 'YData', d);
                    end

                end

            end

            obj.drawOverlays(results);

            obj.showCriteria(obj.H.Criteria, results);

        end

        function drawOverlays(obj, results)

            for ax = [obj.H.Axes, obj.H.NarrowAxes]
                Specs.drawSpecOverlays(ax, results, ...
                    PassColor = CATS.Theme.Success, FailColor = CATS.Theme.Warning);
            end

        end

        function showCriteria(~, tbl, results)

            n = height(results);

            data = cell(n, 4);

            overridable = false(n,1);

            if ismember('Overridable', results.Properties.VariableNames)
                overridable = results.Overridable;
            end

            for k = 1:n

                label = results.Label(k);

                if overridable(k)
                    label = label + " *";      % * = may be overridden
                end

                data{k,1} = char(label);
                data{k,2} = char(CATS.App.formatValue(results.Value(k), results.Units(k)));
                data{k,3} = char(CATS.App.formatLimit(results.Type(k), results.Limit(k), results.Units(k)));
                data{k,4} = char(ifelse(results.Pass(k), "PASS", ifelse(overridable(k), "FAIL*", "FAIL")));

            end

            tbl.Data = data;

            removeStyle(tbl);

            pass = find(results.Pass);
            fail = find(~results.Pass);

            if ~isempty(pass)
                addStyle(tbl, uistyle('BackgroundColor', CATS.Theme.Success, ...
                    'FontColor', CATS.Theme.OnStatus, 'FontWeight', 'bold'), ...
                    'cell', [pass(:) repmat(4, numel(pass), 1)]);
            end

            if ~isempty(fail)
                addStyle(tbl, uistyle('BackgroundColor', CATS.Theme.Warning, ...
                    'FontColor', CATS.Theme.OnStatus, 'FontWeight', 'bold'), ...
                    'cell', [fail(:) repmat(4, numel(fail), 1)]);
            end

        end

    end

    %==============================================================
    % LOG
    %==============================================================
    methods (Access = private)

        function addLogEntry(obj, serial, decision, computedPass, retest, when, override)

            if nargin < 7
                override = "";
            end

            entry = struct('Serial', string(serial), 'Decision', string(decision), ...
                'ComputedPass', computedPass, 'Retest', retest, 'Timestamp', when, ...
                'Override', string(override));

            if isempty(obj.Records)
                obj.Records = entry;
            else
                obj.Records(end+1) = entry;
            end

            obj.updateLog();

        end

        function updateLog(obj)

            recs = obj.Records;

            n = numel(recs);

            data = cell(n, 5);

            for k = 1:n
                r = recs(n - k + 1);          % newest first
                data{k,1} = char(string(r.Timestamp, "HH:mm:ss"));
                data{k,2} = char(r.Serial);
                data{k,3} = char(r.Decision);
                if r.Decision == "SKIPPED"
                    data{k,4} = '';
                elseif strlength(r.Override) > 0
                    data{k,4} = char("override " + extractBefore(r.Override + ":", ":"));
                else
                    data{k,4} = char(ifelse(r.ComputedPass, "all pass", "out of spec"));
                end
                data{k,5} = char(ifelse(r.Retest, "retest", ""));
            end

            obj.H.Log.Data = data;

            removeStyle(obj.H.Log);

            if n > 0
                decisions = string(data(:,3));
                fail = find(decisions == "FAIL");
                pass = find(decisions == "PASS");
                if ~isempty(fail)
                    addStyle(obj.H.Log, uistyle('BackgroundColor', CATS.Theme.Warning, ...
                        'FontColor', CATS.Theme.OnStatus), 'cell', [fail(:) repmat(3,numel(fail),1)]);
                end
                if ~isempty(pass)
                    addStyle(obj.H.Log, uistyle('BackgroundColor', CATS.Theme.Success, ...
                        'FontColor', CATS.Theme.OnStatus), 'cell', [pass(:) repmat(3,numel(pass),1)]);
                end
            end

            if isempty(obj.Batch)

                obj.H.LogSummary.Text = 'No batch running.';

            else

                d = strings(0,1);

                if ~isempty(recs)
                    d = [recs.Decision];
                end

                obj.H.LogSummary.Text = sprintf( ...
                    '%s   %s   Operator %s      Tested %d    PASS %d    FAIL %d    Skipped %d', ...
                    obj.Batch.Profile.Name, obj.Batch.Id, obj.Batch.Operator, ...
                    sum(d ~= "SKIPPED"), sum(d == "PASS"), sum(d == "FAIL"), sum(d == "SKIPPED"));

            end

        end

    end

    %==============================================================
    % CALLBACKS
    %==============================================================
    methods (Access = private)

        function onSweepButton(obj)

            if obj.Sweeping
                obj.stopSweeping();
            else
                obj.startSweeping();
            end

        end

        function onSetSerial(obj)

            if ~obj.EditingSerial

                obj.EditingSerial = true;
                obj.H.Serial.Editable = 'on';
                obj.H.SetSerial.Text = 'Apply';
                CATS.Theme.style(obj.H.SetSerial, "primary");
                focus(obj.H.Serial);

            else

                obj.onSerialEdited(obj.H.Serial.Value);

            end

        end

        function onSerialEdited(obj, value)

            if ~obj.EditingSerial
                return
            end

            obj.EditingSerial = false;
            obj.H.Serial.Editable = 'off';
            obj.H.SetSerial.Text = 'Set Serial...';
            CATS.Theme.style(obj.H.SetSerial, "auto");

            obj.setSerial(value);

        end

        function onTabChanged(obj, tab)

            if tab.Title == "Reports"
                obj.refreshReportLists();
            end

        end

        function onLoadReview(obj)

            [files, folder] = uigetfile({'*.s2p;*.s3p;*.s4p', 'Touchstone files'}, ...
                'Load Touchstone Files', char(obj.Settings.DataRoot), 'MultiSelect', 'on');

            figure(obj.Figure);

            if isequal(files, 0)
                return
            end

            obj.loadReviewFiles(fullfile(folder, string(files)));

        end

        function updateReview(obj)

            ax = obj.H.ReviewAxes;

            cla(ax);

            obj.H.ReviewCriteria.Data = cell(0,4);
            obj.H.ReviewInfo.Text = '';

            if isempty(obj.ReviewItems) || isempty(obj.H.ReviewList.Value)
                return
            end

            selected = obj.ReviewItems(obj.H.ReviewList.Value);

            hold(ax, 'on');

            for item = selected
                s = item.SParams;
                f = s.Frequencies/1e6;
                plot(ax, f, 20*log10(abs(squeeze(s.Parameters(2,1,:)))), ...
                    'LineWidth', 1.4, 'DisplayName', item.Name + " S21");
                if s.NumPorts >= 3
                    plot(ax, f, 20*log10(abs(squeeze(s.Parameters(3,1,:)))), ...
                        'LineWidth', 1.4, 'DisplayName', item.Name + " S31");
                end
            end

            hold(ax, 'off');

            grid(ax, 'on');

            legend(ax, 'Location', 'southwest', 'Interpreter', 'none', 'FontSize', 11);

            % Criteria for the first selected file
            first = selected(1);

            profile = obj.profileByName(string(obj.H.ReviewProfile.Value));

            info = first.Name;

            if ~isempty(first.Record)
                info = sprintf('%s\n%s by %s on %s', first.Name, first.Record.Decision, ...
                    first.Record.Operator, string(first.Record.Timestamp, "yyyy-MM-dd HH:mm"));
            end

            if ~isempty(profile) && first.SParams.NumPorts >= numel(profile.Ports)

                results = Specs.evaluate(first.SParams, profile);

                obj.showCriteria(obj.H.ReviewCriteria, results);

                Specs.drawSpecOverlays(ax, results, ...
                    PassColor = CATS.Theme.Success, FailColor = CATS.Theme.Warning);

                info = sprintf('%s\nAgainst %s: %s', info, profile.Name, ...
                    ifelse(all(results.Pass), "all criteria pass", ...
                    sum(~results.Pass) + " criteria fail"));

            end

            obj.H.ReviewInfo.Text = info;

        end

        function refreshReportLists(obj)

            files = dir(fullfile(obj.Settings.DataRoot, '*', '*', 'Batch_*.csv'));

            items = strings(0,1);
            data = strings(0,1);

            for f = files(:).'
                [~, profileName] = fileparts(f.folder);
                [~, day] = fileparts(fileparts(f.folder));
                id = extractBetween(string(f.name), "Batch_", ".csv");
                items(end+1,1) = day + "   " + profileName + "   " + id; %#ok<AGROW>
                data(end+1,1) = fullfile(f.folder, f.name); %#ok<AGROW>
            end

            [items, order] = sort(items, 'descend');

            obj.H.BatchList.Items = cellstr(items);
            obj.H.BatchList.ItemsData = cellstr(data(order));

            operators = "All operators";

            try
                recent = CATS.Storage.readRecords(obj.Settings.DataRoot, ...
                    From = datetime("today") - days(31));
                if ~isempty(recent)
                    operators = [operators, unique([recent.Operator])];
                end
            catch
            end

            obj.setItems(obj.H.ReportOperator, cellstr(operators));

        end

        function onWriteBatchReport(obj)

            if isempty(obj.H.BatchList.Value)
                obj.H.ReportStatus.Text = 'No batches found in the data folder.';
                return
            end

            logFile = string(obj.H.BatchList.Value);

            [folder, name] = fileparts(logFile);
            [~, profileName] = fileparts(folder);

            profile = obj.profileByName(profileName);

            if isempty(profile)
                obj.H.ReportStatus.Text = "Profile " + profileName + " is not in the profiles folder.";
                return
            end

            id = extractAfter(name, "Batch_");

            log = readtable(logFile, 'TextType', 'string');

            batch = struct('Id', id, 'Root', obj.Settings.DataRoot, 'Profile', profile, ...
                'Start', min(datetime(log.Timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss')), ...
                'ReportFile', fullfile(folder, "Report_" + profileName + "_" + id + ".xlsx"));

            try
                file = obj.writeBatchReport(batch);
                obj.H.ReportStatus.Text = "Report written: " + file;
                obj.openFolder(fileparts(file));
            catch ME
                obj.H.ReportStatus.Text = "Report failed: " + ME.message;
            end

        end

        function onWriteRangeReport(obj)

            try

                from = obj.H.FromDate.Value + duration(obj.H.FromTime.Value, 'InputFormat', 'hh:mm');
                to = obj.H.ToDate.Value + duration(obj.H.ToTime.Value, 'InputFormat', 'hh:mm') + seconds(59);

                operator = string(obj.H.ReportOperator.Value);

                if operator == "All operators"
                    operator = "";
                end

                file = obj.writeRangeReport(string(obj.H.ReportProfile.Value), from, to, operator);

                obj.H.ReportStatus.Text = "Report written: " + file;

                obj.openFolder(fileparts(file));

            catch ME

                obj.H.ReportStatus.Text = "Report failed: " + ME.message;

            end

        end

        function setTheme(obj, mode)

            CATS.Theme.apply(obj.Figure, mode);

            obj.Settings.Theme = mode;
            obj.Settings.save();

        end

        function onThemeChanged(obj)
            % Brand colours are fixed; redraw what is drawn by hand.

            if ~isempty(obj.LastResults) && ~isempty(obj.Batch)
                obj.drawOverlays(obj.LastResults);
            end

            obj.refresh();

        end

        function openSettings(obj)

            d = uifigure('Name', 'CATS Settings', 'Position', [300 300 640 240], ...
                'WindowStyle', 'modal', 'Theme', obj.Figure.Theme.BaseColorStyle, ...
                'Tag', 'CATS_SettingsDialog');

            g = uigridlayout(d, [4 3]);
            g.ColumnWidth = {140, '1x', 100};
            g.RowHeight = {36, 36, 36, 44};

            uilabel(g, 'Text', 'Data folder', 'FontSize', CATS.Theme.FontBase);
            dataField = uieditfield(g, 'text', 'Value', char(obj.Settings.DataRoot), ...
                'FontSize', CATS.Theme.FontBase);
            uibutton(g, 'Text', 'Browse...', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) browse(dataField));

            uilabel(g, 'Text', 'Profiles folder', 'FontSize', CATS.Theme.FontBase);
            profField = uieditfield(g, 'text', 'Value', char(obj.Settings.ProfilesFolder), ...
                'FontSize', CATS.Theme.FontBase);
            uibutton(g, 'Text', 'Browse...', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) browse(profField));

            simBox = uicheckbox(g, 'Text', 'List the simulated VNA (training / testing)', ...
                'Value', obj.Settings.ShowSim, 'FontSize', CATS.Theme.FontBase);
            simBox.Layout.Column = [1 3];

            bg = uigridlayout(g, [1 3]);
            bg.Layout.Column = [1 3];
            bg.ColumnWidth = {'1x', 120, 120};
            bg.Padding = [0 0 0 0];

            save = uibutton(bg, 'Text', 'Save', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) onSave());
            save.Layout.Column = 2;
            CATS.Theme.style(save, "primary");

            cancel = uibutton(bg, 'Text', 'Cancel', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) delete(d));
            cancel.Layout.Column = 3;

            function browse(field)
                folder = uigetdir(field.Value);
                figure(d);
                if ~isequal(folder, 0)
                    field.Value = folder;
                end
            end

            function onSave()
                obj.Settings.DataRoot = string(dataField.Value);
                obj.Settings.ProfilesFolder = string(profField.Value);
                obj.Settings.ShowSim = simBox.Value;
                obj.Settings.save();
                obj.IncludeSim = obj.IncludeSim || simBox.Value;
                delete(d);
                obj.loadProfiles();
                obj.refresh();
            end

        end

        function onClose(obj)

            if ~isempty(obj.Batch) && ~isempty(obj.Records)

                choice = obj.confirm( ...
                    'A batch is running. Finish it (and write its report) before closing?', ...
                    'Close CATS', ["Finish and Close","Close Without Report","Cancel"], "Cancel");

                if choice == "Cancel"
                    return
                elseif choice == "Finish and Close"
                    obj.finishBatch();
                end

            end

            delete(obj);

        end

    end

    %==============================================================
    % PROFILES AND HELPERS
    %==============================================================
    methods (Access = private)

        function loadProfiles(obj)
            % Load profiles; seed the folder from the bundled starter
            % profiles the first time.

            folder = obj.Settings.ProfilesFolder;

            if ~isfolder(folder) || isempty(dir(fullfile(folder, '*.json')))

                bundled = fullfile(CATS.App.appFolder(), 'common', 'Profiles');

                if isfolder(bundled)
                    CATS.Storage.ensureFolder(folder);
                    copyfile(fullfile(bundled, '*.json'), folder);
                    if isfile(fullfile(bundled, 'README.md'))
                        copyfile(fullfile(bundled, 'README.md'), folder);
                    end
                end

            end

            obj.Profiles = Specs.listProfiles(folder);

            names = {};
            if ~isempty(obj.Profiles)
                names = cellstr([obj.Profiles.Name]);
            end

            obj.H.Profile.Items = names;

            if any(strcmp(names, obj.Settings.LastProfile))
                obj.H.Profile.Value = char(obj.Settings.LastProfile);
            end

        end

        function p = selectedProfile(obj)

            p = [];

            if isempty(obj.Profiles) || isempty(obj.H.Profile.Value)
                return
            end

            p = obj.profileByName(string(obj.H.Profile.Value));

        end

        function p = profileByName(obj, name)

            p = [];

            if isempty(obj.Profiles)
                return
            end

            k = find([obj.Profiles.Name] == name, 1);

            if ~isempty(k)
                p = obj.Profiles(k);
            end

        end

        function header = reportHeader(obj, records)

            header = struct();

            header.Software = "CATS " + CATS.App.Version;
            header.WorkOrder = strjoin(unique([records.WorkOrder]), ", ");

            equipment = unique([records.Equipment]);
            equipment = equipment(strlength(equipment) > 0);

            if isempty(equipment) && ~isempty(obj.Driver)
                equipment = obj.VNAInfo.IDN;
            end

            header.Equipment = strjoin(equipment, "; ");

            cal = unique([records.Calibration]);
            cal = cal(strlength(cal) > 0);
            header.Calibration = strjoin(cal, "; ");

        end

        function openFolder(~, folder)

            if isfolder(folder) && ispc
                winopen(folder);
            end

        end

        function answer = confirm(obj, message, title, options, default)
            % uiconfirm, or the next scripted answer when testing.

            if ~isempty(obj.ScriptedAnswers)

                answer = obj.ScriptedAnswers(1);
                obj.ScriptedAnswers(1) = [];

                return

            end

            answer = string(uiconfirm(obj.Figure, message, title, ...
                'Options', cellstr(options), 'DefaultOption', char(default), ...
                'CancelOption', char(options(end))));

        end

        function alert(obj, message, title)

            obj.setStatus(string(title) + ": " + extractBefore(string(message) + newline, newline));

            if ~isempty(obj.ScriptedAnswers) || isempty(obj.Figure) || ~isvalid(obj.Figure)
                return
            end

            uialert(obj.Figure, message, title);

        end

        function text = promptText(obj, title, prompt, default)

            if ~isempty(obj.ScriptedAnswers)
                text = obj.ScriptedAnswers(1);
                obj.ScriptedAnswers(1) = [];
                return
            end

            text = "";

            d = uifigure('Name', title, 'Position', [400 400 720 210], ...
                'WindowStyle', 'modal', 'Theme', obj.Figure.Theme.BaseColorStyle);

            g = uigridlayout(d, [3 3]);
            g.RowHeight = {'1x', 34, 38};
            g.ColumnWidth = {'1x', 110, 110};

            l = uilabel(g, 'Text', prompt, 'FontSize', CATS.Theme.FontBase, 'WordWrap', 'on');
            l.Layout.Column = [1 3];

            f = uieditfield(g, 'text', 'Value', char(default), 'FontSize', CATS.Theme.FontBase);
            f.Layout.Column = [1 3];

            ok = uibutton(g, 'Text', 'OK', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) uiresume(d));
            ok.Layout.Row = 3;
            ok.Layout.Column = 2;
            CATS.Theme.style(ok, "primary");

            cancel = uibutton(g, 'Text', 'Cancel', 'FontSize', CATS.Theme.FontBase, ...
                'ButtonPushedFcn', @(~,~) delete(d));
            cancel.Layout.Row = 3;
            cancel.Layout.Column = 3;

            uiwait(d);

            % Closed or cancelled -> ""
            if isvalid(d)
                text = strtrim(string(f.Value));
                delete(d);
            end

        end

    end

    methods (Static)

        function folder = appFolder()
            % Folder holding CATSApp.m, common/ and the logo (also
            % correct inside the compiled app).

            folder = fileparts(fileparts(mfilename('fullpath')));

        end

        function text = formatValue(value, units)

            if ~isfinite(value)
                text = "N/A";
                return
            end

            switch units
                case "Hz"
                    text = sprintf("%.1f MHz", value/1e6);
                case "s"
                    text = sprintf("%.2f ns", value*1e9);
                otherwise
                    text = sprintf("%.2f %s", value, units);
            end

        end

        function text = formatLimit(type, limit, units)

            types = Specs.criterionTypes();

            info = types(types.Type == type, :);

            if info.Symmetric
                op = "+/-";
            elseif type == "BW_MIN" || info.HigherIsBetter
                op = ">=";
            else
                op = "<=";
            end

            text = op + " " + CATS.App.formatValue(limit, units);

        end

        function [wideX, narrowX, wideY, narrowY] = plotLimits(p)
            % Plot ranges for a profile (Hz, dB). Display.YLimdB and
            % Display.NarrowYLimdB override the defaults: -80..5 dB for
            % the full sweep, -40..2 dB for the passband view.

            wideX = [p.Stimulus.StartHz p.Stimulus.StopHz];

            wideY = [-80 5];

            if isfield(p.Display, 'YLimdB')
                wideY = reshape(p.Display.YLimdB, 1, 2);
            end

            narrowY = [-40 2];

            if isfield(p.Display, 'NarrowYLimdB')
                narrowY = reshape(p.Display.NarrowYLimdB, 1, 2);
            end

            if isfield(p.Display, 'NarrowbandHz')

                narrowX = reshape(p.Display.NarrowbandHz, 1, 2);

            else

                % 3x the widest passband criterion around its centre
                bands = vertcat(p.Criteria(ismember([p.Criteria.Type], ...
                    ["IL_MAX","IL_ABS_MIN"])).BandHz);

                if isempty(bands)
                    narrowX = wideX;
                else
                    centre = mean([min(bands(:,1)) max(bands(:,2))]);
                    span = 3*(max(bands(:,2)) - min(bands(:,1)));
                    narrowX = centre + [-1 1]*span/2;
                end

            end

            narrowX = [max(narrowX(1), wideX(1)) min(narrowX(2), wideX(2))];

        end

    end

end

function out = ifelse(cond, a, b)

if cond
    out = a;
else
    out = b;
end

end
