function app = CATSApp()
% CATSApp
%
% Launch CATS - CTS Acceptance Test System.
%
% This is the entry point for the compiled application. In the compiled
% exe it waits until the window is closed so the program keeps running.
%
% From MATLAB (open CATS.prj, or add this folder and common/ to the path):
%
%   app = CATSApp();
%

root = fileparts(mfilename('fullpath'));

if ~isdeployed && isempty(which('VNA.VNAFactory'))
    addpath(fullfile(root, 'common'));
end

app = CATS.App();

if isdeployed
    waitfor(app.Figure);
end

end
