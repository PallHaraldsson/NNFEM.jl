for i in 100 201 202 203 250
do
    julia Data_NNPlatePull.jl $i 2>&1 | tee Data/$i.txt & 
done