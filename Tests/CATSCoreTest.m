function tests = CATSCoreTest
% CATSCoreTest
%
% Serial numbers, settings and storage (no UI, no hardware).
%
%   runtests("Tests/CATSCoreTest.m")
%

tests = functiontests(localfunctions);

end

function setupOnce(testCase)

root = fileparts(fileparts(mfilename('fullpath')));

testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
    [string(root), fullfile(root, "common")]));

testCase.TestData.Profile = Specs.loadProfile( ...
    fullfile(root, "common", "Profiles", "1235.json"));

end

function setup(testCase)

testCase.TestData.Temp = tempname;
mkdir(testCase.TestData.Temp);

end

function teardown(testCase)

rmdir(testCase.TestData.Temp, 's');

end

%==========================================================
% SERIAL NUMBERS
%==========================================================
function testSerialIncrementKeepsPadding(testCase)

verifyEqual(testCase, CATS.SerialNumber.next("1235-0042"), "1235-0043");
verifyEqual(testCase, CATS.SerialNumber.next("DPX-0099"), "DPX-0100");
verifyEqual(testCase, CATS.SerialNumber.next("99"), "100");
verifyEqual(testCase, CATS.SerialNumber.next("WO3296-17"), "WO3296-18");
verifyEqual(testCase, CATS.SerialNumber.next(" A9 "), "A10");

verifyError(testCase, @() CATS.SerialNumber.next("1235-"), 'CATS:BadSerial');

verifyTrue(testCase, CATS.SerialNumber.isValid("1235-0001"));
verifyFalse(testCase, CATS.SerialNumber.isValid("1235-A"));
verifyFalse(testCase, CATS.SerialNumber.isValid("12/35-1"));
verifyFalse(testCase, CATS.SerialNumber.isValid(""));

end

%==========================================================
% SETTINGS
%==========================================================
function testSettingsRoundTrip(testCase)

file = fullfile(testCase.TestData.Temp, "settings.json");

s = CATS.Settings.load(file);

verifyEqual(testCase, s.Theme, "light");
verifyTrue(testCase, strlength(s.DataRoot) > 0);

s.Theme = "dark";
s.LastOperator = "jdoe";
s.save();

s2 = CATS.Settings.load(file);

verifyEqual(testCase, s2.Theme, "dark");
verifyEqual(testCase, s2.LastOperator, "jdoe");

end

%==========================================================
% STORAGE
%==========================================================
function testSaveReadAndReport(testCase)

p = testCase.TestData.Profile;

root = testCase.TestData.Temp;

batch = CATS.Storage.newBatch(root, p, "jdoe", "WO123");

good = simSweep(p, 1);
bad = simSweep(p, 5);

r1 = CATS.Storage.saveRecord(batch, "1235-0001", good, Specs.evaluate(good,p), "PASS");
r2 = CATS.Storage.saveRecord(batch, "1235-0002", bad,  Specs.evaluate(bad,p),  "FAIL");
CATS.Storage.logSkip(batch, "1235-0003");
pause(1.1);
r3 = CATS.Storage.saveRecord(batch, "1235-0002", good, Specs.evaluate(good,p), "PASS", ...
    struct('Retest', true));

% Folder layout
verifyTrue(testCase, isfile(r1.SweepFile));
verifyTrue(testCase, endsWith(r1.SweepFile, ".s2p"));
verifyTrue(testCase, contains(r1.SweepFile, fullfile(string(datetime("now"),"yyyy-MM-dd"), "1235", "1235-0001", "SweepData")));
verifyTrue(testCase, isfile(r1.MetaFile));
verifyFalse(testCase, r2.ComputedPass);

% Batch log: PASS, FAIL, SKIPPED, retest PASS
log = readtable(batch.LogFile, 'TextType', 'string');
verifyEqual(testCase, log.Decision, ["PASS";"FAIL";"SKIPPED";"PASS"]);
verifyEqual(testCase, log.Retest, [0;0;0;1]);

% Read back by batch; latest per serial keeps the retest
recs = CATS.Storage.readRecords(root, BatchId=batch.Id);
verifyEqual(testCase, numel(recs), 3);

latest = CATS.Storage.latestPerSerial(recs);
verifyEqual(testCase, [latest.Serial], ["1235-0001","1235-0002"]);
verifyEqual(testCase, [latest.Decision], ["PASS","PASS"]);
verifyEqual(testCase, latest(2).MetaFile, r3.MetaFile);
verifyEqual(testCase, latest(1).Results.Value, r1.Results.Value, 'AbsTol', 1e-9);

% Operator filter
verifyEmpty(testCase, CATS.Storage.readRecords(root, Operator="someone else"));

% Report from saved data
Specs.writeReport(latest, p, batch.ReportFile, struct('WorkOrder', batch.WorkOrder));
c = readcell(batch.ReportFile, 'Sheet', "1235");
verifyEqual(testCase, c(15:16,1), {'1235-0001';'1235-0002'});
verifyEqual(testCase, c{10,1}, 'Operator: jdoe');

end

function testReadLogsWithNoLogs(testCase)
% A fresh data folder (no batch logs) must still give typed columns.

log = CATS.Storage.readLogs(testCase.TestData.Temp);

verifyEqual(testCase, height(log), 0);
verifyClass(testCase, log.Decision, 'string');
verifyEmpty(testCase, find(log.Decision == "PASS"));

end

function testReadLogsAfterSaving(testCase)

p = testCase.TestData.Profile;

batch = CATS.Storage.newBatch(testCase.TestData.Temp, p, "jdoe", "WO1");

bad = simSweep(p, 5);
CATS.Storage.saveRecord(batch, "1235-0001", bad, Specs.evaluate(bad, p), "FAIL");
CATS.Storage.logSkip(batch, "1235-0002");

log = CATS.Storage.readLogs(testCase.TestData.Temp);

verifyEqual(testCase, log.Decision, ["SKIPPED"; "FAIL"]);    % newest first
verifyEqual(testCase, log.Failed(2), "IL");
verifyEqual(testCase, log.BatchId, [batch.Id; batch.Id]);

end

function testUncorrectedAndOverrideNotes(testCase)
% Uncorrected / override parts carry a note through the log, the
% metadata and the report NOTES column.

p = testCase.TestData.Profile;

root = testCase.TestData.Temp;

batch = CATS.Storage.newBatch(root, p, "jdoe", "WO1");

good = simSweep(p, 1);
res = Specs.evaluate(good, p);

r1 = CATS.Storage.saveRecord(batch, "1235-0001", good, res, "PASS");
r2 = CATS.Storage.saveRecord(batch, "1235-0002", good, res, "PASS", ...
    struct('Uncorrected', true, 'Override', "HSR: fixture"));

verifyEqual(testCase, r1.Notes, "");
verifyTrue(testCase, r2.Uncorrected);
verifyEqual(testCase, r2.Notes, "UNCORRECTED; Override HSR: fixture");

log = CATS.Storage.readLogs(root);
verifyEqual(testCase, log.Notes, ["UNCORRECTED; Override HSR: fixture"; ""]);

back = CATS.Storage.readRecord(r2.MetaFile);
verifyTrue(testCase, back.Uncorrected);
verifyEqual(testCase, back.Notes, r2.Notes);
verifyFalse(testCase, CATS.Storage.readRecord(r1.MetaFile).Uncorrected);

recs = CATS.Storage.readRecords(root, BatchId=batch.Id);
cells = Specs.writeReport(recs, p, batch.ReportFile);
notesCol = find(strcmp(cells(12,:), 'NOTES'));
verifyNotEmpty(testCase, notesCol);
verifyEqual(testCase, cells{16, notesCol}, 'UNCORRECTED; Override HSR: fixture');

end

%==========================================================
% HELPERS
%==========================================================
function sObj = simSweep(p, lossdB)

cfg = VNA.Utilities.LoadVNAConfig("SIM");
cfg.Ports = p.Ports;
cfg.SimResponse = "Bandpass";
cfg.StartFreq = p.Stimulus.StartHz;
cfg.StopFreq = p.Stimulus.StopHz;
cfg.NumPoints = p.Stimulus.Points;

v = VNA.VNAFactory.create(cfg);
v.AcquireDelaySec = 0;
v.tuneToProfile(p);          % golden part for this profile
v.SimLossdB = lossdB;
v.connect();

sObj = v.acquire();

end
