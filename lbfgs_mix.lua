-- Example to compare torch against l-BFGS mix in immediate mode
-- 60k examples, memory=5, max iterations=100

----------------------------------------------------------------------
-- forked from https://github.com/torch/demos/blob/master/train-a-digit-classifier/train-on-mnist.lua
----------------------------------------------------------------------
-- This script shows how to train different models on the MNIST 
-- dataset, using multiple optimization techniques (SGD, LBFGS)
--
-- This script demonstrates a classical example of training 
-- well-known models (convnet, MLP, logistic regression)
-- on a 10-class classification problem. 
--
-- It illustrates several points:
-- 1/ description of the model
-- 2/ choice of a loss function (criterion) to minimize
-- 3/ creation of a dataset as a simple Lua table
-- 4/ description of training and test procedures
--
-- Clement Farabet
----------------------------------------------------------------------

require 'torch'
require 'nn'
require 'nnx'
require 'optim'
require 'image'
require 'pl'
require 'paths'

require 'lbfgs_reference'
require 'port_util'
require 'dataset-mnist'

----------------------------------------------------------------------
-- parse command-line options
--
local opt = lapp[[
   -s,--save          (default "logs")      subdirectory to save logs
   -n,--network       (default "")          reload pretrained network
   -m,--model         (default "convnet")   type of model tor train: convnet | mlp | linear
   -f,--full                                use the full dataset
   -p,--plot                                plot while training
   -o,--optimization  (default "SGD")       optimization: SGD | LBFGS 
   -r,--learningRate  (default 0.05)        learning rate, for SGD only
   -b,--batchSize     (default 10)          batch size
   -m,--momentum      (default 0)           momentum, for SGD only
   -i,--maxIter       (default 3)           maximum nb of iterations per batch, for LBFGS
   --coefL1           (default 0)           L1 penalty on the weights
   --coefL2           (default 0)           L2 penalty on the weights
   -t,--threads       (default 4)           number of threads
]]

-- fix seed
torch.manualSeed(1)

-- threads
torch.setnumthreads(opt.threads)
print('<torch> set nb of threads to ' .. torch.getnumthreads())

torch.setdefaulttensortype('torch.FloatTensor')
opt.optimization = 'LBFGS'
opt.maxIter = 100
opt.nCorrection = 5
opt.batchSize = 60000
opt.model = 'linear'
opt.coefL2 = 1
opt.full = 1

opt.learningRate = 1
opt.momentum = 0
----------------------------------------------------------------------
-- define model to train
-- on the 10-class classification problem
--
classes = {'1','2','3','4','5','6','7','8','9','10'}

-- geometry: width and height of input images
geometry = {32,32}

nn.oldSeed = 1



if opt.network == '' then
   -- define model to train
   model = nn.Sequential()

   if opt.model == 'convnet' then
      ------------------------------------------------------------
      -- convolutional network 
      ------------------------------------------------------------
      -- stage 1 : mean suppresion -> filter bank -> squashing -> max pooling
      model:add(nn.SpatialConvolutionMM(1, 32, 5, 5))
      model:add(nn.Tanh())
      model:add(nn.SpatialMaxPooling(3, 3, 3, 3))
      -- stage 2 : mean suppresion -> filter bank -> squashing -> max pooling
      model:add(nn.SpatialConvolutionMM(32, 64, 5, 5))
      model:add(nn.Tanh())
      model:add(nn.SpatialMaxPooling(2, 2, 2, 2))
      -- stage 3 : standard 2-layer MLP:
      model:add(nn.Reshape(64*2*2))
      model:add(nn.Linear(64*2*2, 200))
      model:add(nn.Tanh())
      model:add(nn.Linear(200, #classes))
      ------------------------------------------------------------

   elseif opt.model == 'mlp' then
      ------------------------------------------------------------
      -- regular 2-layer MLP
      ------------------------------------------------------------
      model:add(nn.Reshape(1024))
      model:add(nn.Linear(1024, 2048))
      model:add(nn.Tanh())
      model:add(nn.Linear(2048,#classes))
      ------------------------------------------------------------

   elseif opt.model == 'linear' then
      ------------------------------------------------------------
      -- simple linear model: logistic regression
      ------------------------------------------------------------
      model:add(nn.Reshape(1024))
      model:add(nn.Linear(1024,#classes))
      ------------------------------------------------------------

   else
      print('Unknown model type')
      cmd:text()
      error()
   end
else
   print('<trainer> reloading previously trained network')
   model = torch.load(opt.network)
end

-- retrieve parameters and gradients
parameters,gradParameters = model:getParameters()

-- verbose
print('<mnist> using model:')
print(model)

----------------------------------------------------------------------
-- loss function: negative log-likelihood
--
model:add(nn.LogSoftMax())
criterion = nn.ClassNLLCriterion()

----------------------------------------------------------------------
-- get/create dataset
--
nbTrainingPatches = 60000
nbTestingPatches = 10000

trainData = mnist.loadTrainSet(nbTrainingPatches, geometry)

----------------------------------------------------------------------
-- define training and testing functions

-- log results to files
trainLogger = optim.Logger(paths.concat(opt.save, 'train.log'))
testLogger = optim.Logger(paths.concat(opt.save, 'test.log'))

-- training function
function train(dataset)
   -- epoch tracker
   epoch = epoch or 1

   -- local vars
   local time = sys.clock()

   --   print(parameters)
   -- do one epoch
   print('<trainer> on training set:')
   print("<trainer> online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')
 --   for t = 1,dataset:size(),opt.batchSize do
   for t = 1,1 do
      -- create mini batch
      local inputs = torch.Tensor(opt.batchSize,1,geometry[1],geometry[2])
      local targets = torch.Tensor(opt.batchSize)
      local k = 1
      -- fix batch to always start from the same example
      --      for i = t,math.min(t+opt.batchSize-1,dataset:size()) do
      for i = 1, 1+opt.batchSize-1 do
         -- load new sample
         local sample = dataset[i]
         local input = sample[1]:clone()
         local _,target = sample[2]:clone():max(1)
         target = target:squeeze()
         inputs[k] = input
         targets[k] = target
         k = k + 1
      end

      -- create closure to evaluate f(X) and df/dX
      local feval = function(x)
         -- just in case:
         collectgarbage()

         -- get new parameters
         if x ~= parameters then
            parameters:copy(x)
         end

         -- reset gradients
         gradParameters:zero()

         -- evaluate function for complete mini batch
         local outputs = model:forward(inputs)
         local f = criterion:forward(outputs, targets)

         -- estimate df/dW
         local df_do = criterion:backward(outputs, targets)
         model:backward(inputs, df_do)

         -- penalties (L1 and L2):
         if opt.coefL1 ~= 0 or opt.coefL2 ~= 0 then
            -- locals:
            local norm,sign= torch.norm,torch.sign

            -- Loss:
            f = f + opt.coefL1 * norm(parameters,1)
            f = f + opt.coefL2 * norm(parameters,2)^2/2

            -- Gradients:
            gradParameters:add( sign(parameters):mul(opt.coefL1) + parameters:clone():mul(opt.coefL2) )
         end

         -- return f and df/dX
         return f,gradParameters
      end


      new_parameters = torch.ones(10250)
      fval,fgrad = feval(new_parameters)
      print("new_parameters sum", new_parameters:sum())
      print("parameters sum", parameters:sum())
      print("inputs sum", inputs:sum())
      print("targets sum", targets:sum())
      print("Feval", fval)

      -- Perform LBFGS step:
      lbfgsState = lbfgsState or {
	 maxIter = opt.maxIter,
--	 lineSearch = optim.lswolfe
      }
      --      optim.hacked_lbfgs(feval, parameters, lbfgsState)
      optim.lbfgs_reference(feval, new_parameters, lbfgsState)
       
      -- disp report:
      print('LBFGS step')
      print(' - progress in batch: ' .. t .. '/' .. dataset:size())
      print(' - nb of iterations: ' .. lbfgsState.nIter)
      print(' - nb of function evalutions: ' .. lbfgsState.funcEval)

   end
   
   -- time taken
   time = sys.clock() - time
   time = time / dataset:size()
   print("<trainer> time to learn 1 sample = " .. (time*1000) .. 'ms')

   -- save/log current net
   -- local filename = paths.concat(opt.save, 'mnist.net')
   -- os.execute('mkdir -p ' .. sys.dirname(filename))
   -- if paths.filep(filename) then
   --    os.execute('mv ' .. filename .. ' ' .. filename .. '.old')
   -- end
   -- print('<trainer> saving network to '..filename)
   -- -- torch.save(filename, model)

   -- -- next epoch
   -- epoch = epoch + 1
end

-- test function
function test(dataset)
   -- local vars
   local time = sys.clock()

   -- test over given dataset
   print('<trainer> on testing Set:')
   for t = 1,dataset:size(),opt.batchSize do
      -- disp progress
      xlua.progress(t, dataset:size())

      -- create mini batch
      local inputs = torch.Tensor(opt.batchSize,1,geometry[1],geometry[2])
      local targets = torch.Tensor(opt.batchSize)
      local k = 1
      for i = t,math.min(t+opt.batchSize-1,dataset:size()) do
         -- load new sample
         local sample = dataset[i]
         local input = sample[1]:clone()
         local _,target = sample[2]:clone():max(1)
         target = target:squeeze()
         inputs[k] = input
         targets[k] = target
         k = k + 1
      end

      -- test samples
      local preds = model:forward(inputs)

      -- confusion:
      for i = 1,opt.batchSize do
         confusion:add(preds[i], targets[i])
      end
   end

   -- timing
   time = sys.clock() - time
   time = time / dataset:size()
--   print("<trainer> time to test 1 sample = " .. (time*1000) .. 'ms')

   -- print confusion matrix
--   print(confusion)
--   testLogger:add{['% mean class accuracy (test set)'] = confusion.totalValid * 100}
--   confusion:zero()
end

----------------------------------------------------------------------
-- and train!
--
while true do
   -- train/test
--   test(testData)
   train(trainData)
--   test(testData)

   -- plot errors
   if opt.plot then
      trainLogger:style{['% mean class accuracy (train set)'] = '-'}
      testLogger:style{['% mean class accuracy (test set)'] = '-'}
      trainLogger:plot()
      testLogger:plot()
   end
   break
end
