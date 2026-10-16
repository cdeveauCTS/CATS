function tests = HP8753StationTest
% HP8753StationTest
%
% CATS at a station with an HP 8753ES (stand-in instrument Fake8753 from
% common/Tests): wideband profiles are refused at Start Batch; a
% narrowband profile with an 8753ES sweep runs end to end.
%
%   runtests("Tests/HP8753StationTest.m")
%

tests = functiontests(localfunctions);

end

function setupOnce(testCase)

root = fileparts(fileparts(mfilename('fullpath')));

testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
    [string(root), fullfile(root, "common"), fullfile(root, "common", "Tests")]));

testCase.TestData.Root = root;

end

function setup(testCase)

temp = tempname;
mkdir(temp);
testCase.TestData.Temp = temp;

profiles = fullfile(temp, "Profiles");
mkdir(profiles);

source = fullfile(testCase.TestData.Root, "common", "Profiles", "1233.json");
copyfile(source, profiles);

% Narrowband part: the 1233's passband criteria only, with an 8753ES sweep
p = jsondecode(fileread(source));
p.Name = "NB1233";
p.Description = "1233 passband criteria only (8753ES test)";
criteria = p.Criteria;
if ~iscell(criteria)
    criteria = num2cell(criteria);       % jsondecode gives either form
end
keep = cellfun(@(c) ismember(string(c.Id), ["IL","RL","RIP","GD","BW1","BW6"]), criteria);
p.Criteria = criteria(keep);
p.StimulusByModel.HP8753ES = struct('StartHz', 1.6e9, 'StopHz', 2.1e9, ...
    'Points', 1601, 'IFBWHz', 3000, 'PowerdBm', 0);

fid = fopen(fullfile(profiles, "NB1233.json"), 'w');
fprintf(fid, '%s', jsonencode(p, PrettyPrint=true));
fclose(fid);

settingsFile = fullfile(temp, "settings.json");
s = CATS.Settings.load(settingsFile);
s.DataRoot = fullfile(temp, "Data");
s.ProfilesFolder = profiles;
s.save();

app = CATS.App(SettingsFile=settingsFile, AutoConnect=false);

cfg = VNA.Utilities.LoadVNAConfig("HP8753ES");
cfg.ConnectionAddress = "16";

fake = Fake8753();
fake.Start = 1e6;
fake.Stop = 3e9;

driver = VNA.VNAFactory.create(cfg);
driver.Session = fake;
driver.connect();

app.attachDriver(driver, "HP8753ES", "GPIB0::16::INSTR", driver.getIDN());

testCase.TestData.App = app;
testCase.TestData.Fake = fake;

end

function teardown(testCase)

delete(testCase.TestData.App);

if isfolder(testCase.TestData.Temp)
    rmdir(testCase.TestData.Temp, 's');
end

end

%==========================================================
% TESTS
%==========================================================
function testWidebandProfileRefused(testCase)

app = testCase.TestData.App;

choose(app, "1233", "1233-0001");

app.ScriptedAnswers = "OK";       % answers the alert
app.startBatch();

verifyEmpty(testCase, app.Batch);

status = string(findobj(app.Figure, 'Tag', 'CATS_Status').Text);
verifyTrue(testCase, contains(status, "can't test 1233"), status);

end

function testNarrowbandProfileRuns(testCase)

app = testCase.TestData.App;
fake = testCase.TestData.Fake;

choose(app, "NB1233", "NB-0001");

app.ScriptedAnswers = "Done";     % ECal prompt
app.startBatch();

verifyNotEmpty(testCase, app.Batch);
verifyEqual(testCase, [fake.Start fake.Stop fake.Points fake.IFBW], [1.6e9 2.1e9 1601 3000]);
verifyTrue(testCase, app.CalVerified);

app.sweepOnce();
verifyEqual(testCase, numel(app.LastSweep.Frequencies), 1601);
verifyEqual(testCase, app.LastSweep.NumPorts, 2);

app.record("FAIL");             % the stand-in is not a filter

saved = dir(fullfile(testCase.TestData.Temp, "Data", "**", "*.s2p"));
verifyNumElements(testCase, saved, 1);

app.ScriptedAnswers = "OK";
app.finishBatch();

end

%==========================================================
% HELPERS
%==========================================================
function choose(app, profile, serial)

c = findobj(app.Figure, 'Tag', 'CATS_Profile');
c.Value = char(profile);
c = findobj(app.Figure, 'Tag', 'CATS_StartSerial');
c.Value = char(serial);

end
