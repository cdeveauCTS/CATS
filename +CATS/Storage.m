classdef Storage
    % Storage
    %
    % Saved test data layout (under the DataRoot setting):
    %
    %   <Root>/<yyyy-MM-dd>/<Profile>/
    %       Batch_<BatchId>.csv                 batch log (one row per
    %                                           PASS / FAIL / SKIPPED)
    %       Report_<Profile>_<BatchId>.xlsx     batch report
    %       <Serial>/SweepData/<Serial>_<ts>.s2p|.s3p
    %       <Serial>/Metadata/<Serial>_<ts>.json
    %
    % The date folder is the date the part was tested. Reports are built
    % from the metadata files, so any date range / operator / batch can
    % be reported later.
    %

    methods (Static)

        %==========================================================
        % BATCH
        %==========================================================
        function batch = newBatch(root, profile, operator, workOrder)

            start = datetime("now");

            batch = struct();
            batch.Id = string(start, "yyyyMMdd_HHmmss");
            batch.Root = string(root);
            batch.Profile = profile;
            batch.Operator = string(operator);
            batch.WorkOrder = string(workOrder);
            batch.Start = start;

            folder = CATS.Storage.profileFolder(root, profile.Name, start);

            batch.LogFile = fullfile(folder, "Batch_" + batch.Id + ".csv");
            batch.ReportFile = fullfile(folder, ...
                "Report_" + profile.Name + "_" + batch.Id + ".xlsx");

        end

        %==========================================================
        % SAVE ONE TESTED PART
        %==========================================================
        function record = saveRecord(batch, serial, sObj, results, decision, info)
            % Save the sweep and metadata for one PASS/FAIL decision and
            % append it to the batch log.
            %
            % info (struct, optional fields):
            %   Retest, VNA (Model/IDN/Resource), Calibration, Software,
            %   Override (e.g. "HSR: fixture coupling..."; PASS only)

            arguments
                batch struct
                serial {mustBeTextScalar}
                sObj sparameters
                results table
                decision {mustBeMember(decision, ["PASS","FAIL"])}
                info struct = struct()
            end

            serial = string(serial);

            now_ = datetime("now");

            partFolder = fullfile(CATS.Storage.profileFolder( ...
                batch.Root, batch.Profile.Name, now_), serial);

            sweepFolder = fullfile(partFolder, "SweepData");
            metaFolder = fullfile(partFolder, "Metadata");

            CATS.Storage.ensureFolder(sweepFolder);
            CATS.Storage.ensureFolder(metaFolder);

            base = serial + "_" + string(now_, "yyyyMMdd_HHmmss");

            ext = sprintf(".s%dp", sObj.NumPorts);

            suffix = 1;
            name = base;

            while isfile(fullfile(sweepFolder, name + ext))
                suffix = suffix + 1;
                name = base + "_" + suffix;
            end

            sweepFile = fullfile(sweepFolder, name + ext);
            metaFile = fullfile(metaFolder, name + ".json");

            rfwrite(sObj, sweepFile);

            record = struct( ...
                'Serial', serial, ...
                'Timestamp', now_, ...
                'Decision', string(decision), ...
                'ComputedPass', all(results.Pass), ...
                'Retest', getOr(info, 'Retest', false), ...
                'Override', string(getOr(info, 'Override', "")), ...
                'Operator', batch.Operator, ...
                'WorkOrder', batch.WorkOrder, ...
                'BatchId', batch.Id, ...
                'Profile', batch.Profile.Name, ...
                'Results', results, ...
                'SweepFile', string(sweepFile), ...
                'MetaFile', string(metaFile));

            meta = struct();

            meta.Part = struct('Serial', serial, 'Profile', batch.Profile.Name, ...
                'PartType', batch.Profile.PartType, 'Retest', record.Retest);

            meta.Batch = struct('Id', batch.Id, 'Operator', batch.Operator, ...
                'WorkOrder', batch.WorkOrder, ...
                'Start', string(batch.Start, "yyyy-MM-dd HH:mm:ss"));

            meta.Test = struct( ...
                'Timestamp', string(now_, "yyyy-MM-dd HH:mm:ss"), ...
                'Decision', record.Decision, ...
                'ComputedPass', record.ComputedPass, ...
                'Override', record.Override, ...
                'Software', string(getOr(info, 'Software', "CATS")));

            meta.Results = CATS.Storage.resultsToStruct(results);

            meta.VNA = getOr(info, 'VNA', struct());
            meta.Calibration = getOr(info, 'Calibration', struct());

            profile = batch.Profile;
            meta.Profile = rmfield(profile, intersect(fieldnames(profile), {'File'}));
            meta.Profile.SourceFile = string(getOr(profile, 'File', ""));

            meta.Files = struct('Sweep', record.SweepFile, 'Metadata', record.MetaFile);

            CATS.Storage.writeJson(metaFile, meta);

            CATS.Storage.appendLog(batch, record.Serial, record.Decision, ...
                record.ComputedPass, record.Retest, record.SweepFile, now_, ...
                record.Override, strjoin(results.Id(~results.Pass), ","));

        end

        function logSkip(batch, serial)

            CATS.Storage.appendLog(batch, string(serial), "SKIPPED", ...
                false, false, "", datetime("now"), "", "");

        end

        %==========================================================
        % READ BATCH LOGS (FOR THE LOG TAB)
        %==========================================================
        function log = readLogs(root, fromDay, toDay)
            % All batch-log rows (PASS / FAIL / SKIPPED) for the test
            % dates fromDay..toDay, newest first. Columns:
            % Timestamp, Serial, Decision, Failed, Override, Retest,
            % Operator, Profile, BatchId

            arguments
                root {mustBeTextScalar}
                fromDay datetime = datetime("today")
                toDay datetime = datetime("today")
            end

            names = {'Timestamp','Serial','Decision','Failed','Override', ...
                'Retest','Operator','Profile','BatchId'};

            log = cell2table(cell(0, numel(names)), 'VariableNames', names);

            parts = {};

            for day = dateshift(fromDay,'start','day'):caldays(1):dateshift(toDay,'start','day')

                files = dir(fullfile(root, string(day, "yyyy-MM-dd"), '*', 'Batch_*.csv'));

                for f = files(:).'

                    try
                        t = readtable(fullfile(f.folder, f.name), 'TextType', 'string', ...
                            'Delimiter', ',', 'Format', 'auto');
                    catch
                        continue
                    end

                    if height(t) == 0
                        continue
                    end

                    % Columns added in later versions
                    for opt = ["Override","Failed"]
                        if ~ismember(opt, t.Properties.VariableNames)
                            t.(opt) = strings(height(t), 1);
                        end
                    end

                    t.Override = fillmissing(string(t.Override), 'constant', "");
                    t.Failed = fillmissing(string(t.Failed), 'constant', "");

                    id = extractBetween(string(f.name), "Batch_", ".csv");

                    % Rows are appended in order; a millisecond per row
                    % keeps that order for entries within the same second
                    when = datetime(string(t.Timestamp), 'InputFormat', 'yyyy-MM-dd HH:mm:ss') + ...
                        milliseconds((1:height(t))');

                    parts{end+1} = table( ...
                        when, ...
                        string(t.Serial), string(t.Decision), t.Failed, t.Override, ...
                        logical(t.Retest), string(t.Operator), string(t.Profile), ...
                        repmat(id, height(t), 1), 'VariableNames', names); %#ok<AGROW>

                end

            end

            if ~isempty(parts)
                log = sortrows(vertcat(parts{:}), 'Timestamp', 'descend');
            end

        end

        %==========================================================
        % READ RECORDS (FOR REPORTS / REVIEW)
        %==========================================================
        function records = readRecords(root, options)
            % Read saved metadata into report records (see
            % Specs.writeReport). Filters are optional.

            arguments
                root {mustBeTextScalar}
                options.From datetime = datetime(2000,1,1)
                options.To datetime = datetime(2100,1,1)
                options.Profile string = ""
                options.Operator string = ""
                options.BatchId string = ""
            end

            records = struct([]);

            dateFolders = dir(fullfile(root, '*-*-*'));

            for d = dateFolders(:).'

                if ~d.isdir
                    continue
                end

                day = datetime(d.name, 'InputFormat', 'yyyy-MM-dd', 'Format', 'yyyy-MM-dd');

                if isnat(day) || day < dateshift(options.From,'start','day') || ...
                        day > dateshift(options.To,'start','day')
                    continue
                end

                pattern = fullfile(d.folder, d.name, '*', '*', 'Metadata', '*.json');

                for f = dir(pattern).'

                    rec = CATS.Storage.readRecord(fullfile(f.folder, f.name));

                    if isempty(rec) || ...
                            (strlength(options.Profile) > 0 && rec.Profile ~= options.Profile) || ...
                            (strlength(options.Operator) > 0 && rec.Operator ~= options.Operator) || ...
                            (strlength(options.BatchId) > 0 && rec.BatchId ~= options.BatchId) || ...
                            rec.Timestamp < options.From || rec.Timestamp > options.To
                        continue
                    end

                    if isempty(records)
                        records = rec;
                    else
                        records(end+1) = rec; %#ok<AGROW>
                    end

                end

            end

            if ~isempty(records)
                [~, order] = sort([records.Timestamp]);
                records = records(order);
            end

        end

        function rec = readRecord(metaFile)
            % One metadata JSON -> report record ([] if not CATS data).

            rec = [];

            try
                meta = jsondecode(fileread(metaFile));
            catch
                return
            end

            if ~isfield(meta, 'Part') || ~isfield(meta, 'Results')
                return
            end

            r = meta.Results;

            if iscell(r)
                r = [r{:}];
            end

            value = arrayfun(@(x) numOrNaN(x.Value), r(:));

            results = table(string({r.Id})', string({r.Label})', ...
                string({r.Type})', value, ...
                arrayfun(@(x) numOrNaN(x.Limit), r(:)), ...
                logical([r.Pass])', string({r.Units})', ...
                'VariableNames', {'Id','Label','Type','Value','Limit','Pass','Units'});

            rec = struct( ...
                'Serial', string(meta.Part.Serial), ...
                'Timestamp', datetime(meta.Test.Timestamp, 'InputFormat', 'yyyy-MM-dd HH:mm:ss'), ...
                'Decision', string(meta.Test.Decision), ...
                'ComputedPass', logical(meta.Test.ComputedPass), ...
                'Override', fieldOr(meta, ["Test","Override"]), ...
                'Retest', logical(meta.Part.Retest), ...
                'Operator', string(meta.Batch.Operator), ...
                'WorkOrder', string(meta.Batch.WorkOrder), ...
                'BatchId', string(meta.Batch.Id), ...
                'Profile', string(meta.Part.Profile), ...
                'Results', results, ...
                'SweepFile', string(meta.Files.Sweep), ...
                'MetaFile', string(metaFile), ...
                'Equipment', fieldOr(meta, ["VNA","IDN"]), ...
                'Calibration', fieldOr(meta, ["Calibration","Calset"]));

        end

        function records = latestPerSerial(records)
            % Keep the most recent record of each serial (retests
            % replace earlier results), in first-tested order.

            if isempty(records)
                return
            end

            serials = [records.Serial];

            [~, last] = unique(serials, 'last');

            records = records(sort(last));

        end

        %==========================================================
        % HELPERS
        %==========================================================
        function folder = profileFolder(root, profileName, when)

            folder = fullfile(string(root), string(when, "yyyy-MM-dd"), ...
                string(profileName));

        end

        function s = resultsToStruct(results)

            s = struct('Id', cellstr(results.Id), ...
                'Label', cellstr(results.Label), ...
                'Type', cellstr(results.Type), ...
                'Value', num2cell(results.Value), ...
                'Limit', num2cell(results.Limit), ...
                'Pass', num2cell(results.Pass), ...
                'Units', cellstr(results.Units));

        end

        function writeJson(file, data)

            fid = fopen(file, 'w');

            fprintf(fid, '%s', jsonencode(data, PrettyPrint=true));

            fclose(fid);

        end

        function ensureFolder(folder)

            if ~isfolder(folder)
                mkdir(folder);
            end

        end

    end

    methods (Static, Access = private)

        function appendLog(batch, serial, decision, computedPass, retest, sweepFile, when, override, failed)

            CATS.Storage.ensureFolder(fileparts(batch.LogFile));

            isNew = ~isfile(batch.LogFile);

            fid = fopen(batch.LogFile, 'a');

            if fid < 0
                warning('CATS:Log', 'Could not write %s', batch.LogFile);
                return
            end

            cleanup = onCleanup(@() fclose(fid));

            if isNew
                fprintf(fid, ['Timestamp,Serial,Decision,ComputedPass,Retest,' ...
                    'Operator,WorkOrder,Profile,SweepFile,Override,Failed\n']);
            end

            fprintf(fid, '%s,%s,%s,%d,%d,%s,%s,%s,"%s","%s","%s"\n', ...
                string(when, "yyyy-MM-dd HH:mm:ss"), serial, decision, ...
                computedPass, retest, batch.Operator, batch.WorkOrder, ...
                batch.Profile.Name, sweepFile, strrep(override, '"', ''''), failed);

        end

    end

end

function value = getOr(s, name, default)

if isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default;
end

end

function value = fieldOr(s, path)
% Nested field as a string, "" if any level is missing.

value = "";

for name = path
    if ~isstruct(s) || ~isfield(s, name)
        return
    end
    s = s.(name);
end

value = string(s);

end

function v = numOrNaN(x)

if isempty(x)
    v = NaN;
else
    v = double(x);
end

end
