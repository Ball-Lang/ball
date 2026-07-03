
namespace {


} // namespace

int main() {
    auto xs = BallDyn(std::vector<int64_t>{static_cast<int64_t>(1), static_cast<int64_t>(2), static_cast<int64_t>(3), static_cast<int64_t>(4), static_cast<int64_t>(5)});
    std::cout << ball_to_string(ball_to_string(ball_length(xs))) << std::endl;
    auto sum = BallDyn(static_cast<int64_t>(0));
    for (auto i = static_cast<int64_t>(0); (i < ball_length(xs)); ball_assign(i, (i + static_cast<int64_t>(1)))) {
        ball_assign(sum, (sum + static_cast<BallDyn>(xs)[i]));
    }
    std::cout << ball_to_string(ball_to_string(sum)) << std::endl;
    return 0;
}
